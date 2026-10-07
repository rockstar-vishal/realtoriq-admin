# frozen_string_literal: true

module Facebook
  # Checks the login token and each subscribed page token. A bad token is
  # claimed once, and only that worker sends the alert.
  class TokenManager
    PAGE_MESSAGE = "This Facebook Page needs to be connected again"

    def self.health_check!(connection)
      new(connection).health_check!
    end

    def self.handle_api_error(connection, error, page: nil)
      new(connection).handle_api_error(error, page:)
    end

    def initialize(connection)
      @connection = connection
    end

    # False when the login token is dead, or a Page token could not be read.
    # A dead Page token stops that Page only. The login stays active.
    def health_check!
      check_user_token!
      unverified = check_page_tokens!
      return false if unverified

      @connection.mark_active!
      true
    rescue Errors::TokenInvalidError => e
      invalidate!(e)
      false
    rescue StandardError => e
      Log.error("token_health", connection_id: @connection.id, error_class: e.class.name)
      @connection.update!(error_details: { "message" => "Health check failed", "timestamp" => Time.current.iso8601 })
      false
    end

    def handle_api_error(error, page: nil)
      return unless token_invalid_error?(error)

      page ? invalidate_page!(page) : invalidate!(error)
    end

    private

    def invalidate!(error)
      return unless @connection.claim_invalid!(error_code: error.respond_to?(:fb_error_code) ? error.fb_error_code : nil,
                                                message: "Facebook access expired")

      TokenInvalidAlertJob.perform_later(@connection.firm_id, @connection.id)
    end

    # True only for the worker that moved the Page into error, so a burst of
    # leads does not send the notice again.
    def invalidate_page!(page)
      now = Time.current
      claimed = FacebookPage.across_firms.where(id: page.id).where.not(status: "error").update_all(
        status: "error",
        status_message: PAGE_MESSAGE,
        updated_at: now
      )
      return unless claimed == 1

      page.reload
      PageAttentionJob.perform_later(page.firm_id, page.id)
    end

    def check_user_token!
      if @connection.system_access?
        check_system_user_token!
      else
        GraphApiClient.new(access_token: @connection.access_token).verify_token
      end
    end

    def check_system_user_token!
      valid = nil
      app_api = GraphApiClient.new(access_token: OauthService.new.app_access_token)
      debug_info = app_api.debug_token(input_token: @connection.access_token)
      valid = token_debug_valid?(debug_info)
      if valid == false
        raise Errors::TokenInvalidError.new("System user token is no longer valid", fb_error_code: "190")
      end

      GraphApiClient.new(access_token: @connection.access_token).verify_token(fields: "id,client_business_id")
    rescue Errors::TokenInvalidError
      raise
    rescue Errors::Base => e
      raise unless valid == true && e.fb_error_code.to_s == "100"
    end

    # True when at least one Page could not be checked. Those Pages stay as
    # they are. A definite invalid token marks that Page only.
    def check_page_tokens!
      unverified = false
      app_api = GraphApiClient.new(access_token: OauthService.new.app_access_token)
      @connection.facebook_pages.where(status: "active", subscribed: true).find_each do |page|
        debug_info = app_api.debug_token(input_token: page.page_access_token)
        valid = token_debug_valid?(debug_info)
        if valid == false
          invalidate_page!(page)
        elsif valid != true
          unverified = true
          Log.warn("page_token_unverified", page_id: page.page_id)
        end
      rescue Errors::Base => e
        unverified = true
        Log.warn("page_token_check", page_id: page.page_id, code: e.fb_error_code)
      end
      unverified
    end

    def token_debug_valid?(debug_info)
      return nil unless debug_info.is_a?(Hash)

      value = debug_info["is_valid"]
      value = debug_info.dig("data", "is_valid") if value.nil? && debug_info["data"].is_a?(Hash)
      return nil if value.nil?

      ActiveModel::Type::Boolean.new.cast(value)
    end

    def token_invalid_error?(error)
      error.is_a?(Errors::TokenInvalidError) ||
        (error.respond_to?(:fb_error_code) && Errors::INVALID_TOKEN_CODES.include?(error.fb_error_code.to_s))
    end
  end
end
