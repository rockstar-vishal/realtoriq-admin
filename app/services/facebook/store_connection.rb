# frozen_string_literal: true

module Facebook
  # Turns a completed login into the firm's one active connection.
  # Page subscriptions are refreshed only after that transaction commits.
  class StoreConnection
    Result = Struct.new(:ok?, :error_code, :details, :warnings, :connection, :kept_ids, keyword_init: true)
    SUBSCRIPTION_MESSAGE = "Couldn't refresh the lead subscription. If leads stop, press Subscribe again."

    def self.call(attempt:, actor:)
      new(attempt:, actor:).call
    end

    def initialize(attempt:, actor:)
      @attempt = attempt
      @actor = actor
    end

    def call
      oauth = attempt.oauth_result
      if oauth.blank? || oauth[:fb_user_id].blank? || oauth[:long_lived_token].blank?
        return fail_attempt("exchange_failed")
      end

      pages = Array(oauth[:pages]).select { |page| page[:page_id].present? && page[:page_access_token].present? }
      return fail_attempt("no_pages") if pages.empty?

      held = held_by_another_firm(pages)
      free = without_held(pages, held)
      if free.empty?
        return fail_attempt("page_taken", details: { pages: held.map(&:page_name) })
      end

      missing = missing_subscribed_pages(free)
      if missing.any?
        return fail_attempt("missing_subscribed_pages", details: { pages: missing.map(&:page_name) })
      end

      kept_ids = subscribed_page_ids
      connection = nil
      # requires_new so a unique-index failure rolls back a savepoint. The
      # lock's transaction stays usable and the rescue can still answer 422.
      ActiveRecord::Base.transaction(requires_new: true) do
        release_stale_pages!(free.map { |page| page[:page_id].to_s })
        disconnect_others!
        connection = create_connection!(oauth)
        free.each { |page_data| upsert_page!(connection, page_data, kept_ids) }
        attempt.update!(status: "consumed", result: nil, error_code: nil)
        AuditEvent.record!(subject: connection, action: "facebook.connect", actor:, firm: attempt.firm)
      end

      Result.new(ok?: true, warnings: page_taken_warnings(held), connection:, kept_ids:)
    rescue ActiveRecord::RecordNotUnique
      recover_unique(pages)
    rescue ActiveRecord::RecordInvalid => e
      recover_invalid(pages, e)
    end

    private

    attr_reader :attempt, :actor

    def fail_attempt(code, details: nil)
      attempt.void!(error_code: code)
      Result.new(ok?: false, error_code: code, details:)
    end

    def recover_unique(pages)
      held = held_by_another_firm(pages)
      if without_held(pages, held).empty? && held.any?
        fail_attempt("page_taken", details: { pages: held.map(&:page_name) })
      else
        Result.new(ok?: false, error_code: "already_connected")
      end
    end

    def recover_invalid(pages, error)
      return Result.new(ok?: false, error_code: "exchange_failed") unless page_conflict?(error)

      held = held_by_another_firm(pages)
      names = held.map(&:page_name)
      names = [ error.record.page_name.presence || "This Page" ] if names.empty?
      fail_attempt("page_taken", details: { pages: names })
    end

    def page_conflict?(error)
      error.record.is_a?(FacebookPage) && error.record.errors[:page_id].present?
    end

    def held_by_another_firm(pages)
      ids = page_ids(pages)
      return [] if ids.empty?

      FacebookPage.across_firms.held.where(page_id: ids).where.not(firm_id: attempt.firm_id).to_a
    end

    def without_held(pages, held)
      taken_ids = held.map { |page| page.page_id.to_s }
      pages.reject { |page| taken_ids.include?(page[:page_id].to_s) }
    end

    def page_ids(pages)
      Array(pages).filter_map { |page| page[:page_id].to_s.presence }
    end

    def page_taken_warnings(held)
      held.map do |page|
        {
          "kind" => "page_taken",
          "page_id" => page.page_id,
          "page_name" => page.page_name
        }
      end
    end

    def missing_subscribed_pages(pages)
      granted = pages.map { |page| page[:page_id].to_s }
      current_pages.select { |page| page.subscribed? && granted.exclude?(page.page_id.to_s) }
    end

    def subscribed_page_ids
      current_pages.select(&:subscribed?).map { |page| page.page_id.to_s }
    end

    def current_pages
      current = FacebookConnection.current_for(attempt.firm)
      return [] if current.nil?

      current.facebook_pages.to_a
    end

    def release_stale_pages!(page_ids)
      FacebookPage.across_firms.stale.where(page_id: page_ids).where.not(firm_id: attempt.firm_id).find_each do |page|
        ReleasePage.delete_row!(page, actor:)
      end
    end

    # Clear every previous Page token, then upsert writes the new grant back.
    # A Page that was not in this grant keeps its row and loses the token.
    def disconnect_others!
      FacebookConnection.where(firm_id: attempt.firm_id).where.not(status: "disconnected").find_each do |row|
        row.facebook_pages.find_each { |page| page.update!(page_access_token: nil) }
        row.update!(status: "disconnected", access_token: nil)
      end
    end

    def create_connection!(oauth)
      FacebookConnection.create!(
        firm: attempt.firm,
        connected_by_user: attempt.user,
        fb_user_id: oauth[:fb_user_id],
        fb_user_name: oauth[:fb_user_name],
        client_business_id: oauth[:client_business_id],
        token_kind: oauth[:token_kind].presence || "user_access",
        access_token: oauth[:long_lived_token],
        token_expires_at: oauth[:expires_at],
        token_obtained_at: Time.current,
        status: "active",
        error_code: nil,
        error_details: {}
      )
    end

    def upsert_page!(connection, page_data, kept_ids)
      page = FacebookPage.find_or_initialize_by(firm_id: attempt.firm_id, page_id: page_data[:page_id].to_s)
      kept = kept_ids.include?(page.page_id.to_s)
      page.facebook_connection = connection
      page.page_name = page_data[:page_name].presence || page.page_name.presence || "Page #{page.page_id}"
      page.page_access_token = page_data[:page_access_token]
      page.subscribed = kept
      page.status = kept ? "active" : "unsubscribed"
      page.status_message = nil unless kept
      page.save!
    end

    def self.refresh(connection, kept_ids)
      new(attempt: nil, actor: nil).send(:refresh_subscriptions, connection, kept_ids)
    end

    def refresh_subscriptions(connection, kept_ids)
      return [] if kept_ids.empty?

      warnings = []
      connection.facebook_pages.where(page_id: kept_ids).find_each do |page|
        refresh_page(page, warnings)
      end
      warnings
    end

    def refresh_page(page, warnings)
      client = GraphApiClient.new(access_token: page.page_access_token)
      if client.subscribed_apps(page.page_id)
        page.update!(status_message: nil)
      else
        warn_page(page, warnings)
      end
    rescue StandardError => e
      Log.error("refresh_subscription", page_id: page.page_id, error_class: e.class.name,
        code: (e.fb_error_code if e.respond_to?(:fb_error_code)))
      warn_page(page, warnings)
    end

    def warn_page(page, warnings)
      page.update!(
        subscribed: true,
        status: "active",
        status_message: SUBSCRIPTION_MESSAGE
      )
      warnings << {
        "kind" => "subscription_refresh",
        "page_id" => page.id,
        "page_name" => page.page_name
      }
    end
  end
end
