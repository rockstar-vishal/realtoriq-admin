# frozen_string_literal: true

module Notifications
  # Saves this browser's push subscription on the current session. The same
  # endpoint signed in as someone else is reassigned, not rejected.
  class RegisterPushSubscription
    Result = Struct.new(:ok?, :error_code, :error_message, keyword_init: true)

    def self.call(...)
      new(...).call
    end

    def initialize(user:, session:, endpoint:, p256dh:, auth_key:, content_encoding:, user_agent:)
      @user = user
      @session = session
      @endpoint = endpoint.to_s.strip
      @p256dh = p256dh.to_s.strip
      @auth_key = auth_key.to_s.strip
      @content_encoding = content_encoding.to_s.strip.presence || "aes128gcm"
      @user_agent = user_agent.to_s.first(300).presence
    end

    def call
      if endpoint.blank? || p256dh.blank? || auth_key.blank?
        return Result.new(ok?: false, error_code: "invalid",
                          error_message: "A push subscription needs an endpoint and its two keys.")
      end

      attrs = {
        user:,
        firm_id: user.firm_id,
        auth_session: session,
        endpoint:,
        p256dh:,
        auth_key:,
        content_encoding:,
        user_agent:
      }

      existing = PushSubscription.find_by_endpoint(endpoint)
      if existing
        existing.update!(attrs)
      else
        PushSubscription.create!(attrs)
      end

      Result.new(ok?: true)
    rescue ActiveRecord::RecordNotUnique
      retry_reassign
    end

    private

    attr_reader :user, :session, :endpoint, :p256dh, :auth_key, :content_encoding, :user_agent

    def retry_reassign
      existing = PushSubscription.find_by_endpoint(endpoint)
      return Result.new(ok?: false, error_code: "invalid", error_message: "Could not save this browser.") if existing.nil?

      existing.update!(
        user:, firm_id: user.firm_id, auth_session: session,
        p256dh:, auth_key:, content_encoding:, user_agent:
      )
      Result.new(ok?: true)
    end
  end
end
