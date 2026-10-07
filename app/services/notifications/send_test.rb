# frozen_string_literal: true

module Notifications
  # A test ignores notification_mode. The API path sends only to the current
  # session. The console path sends to every subscription that broker has.
  class SendTest
    Result = Struct.new(:ok?, :notification, :error_code, :error_message, :deliveries, keyword_init: true) do
      def accepted_count
        deliveries.count { |delivery| delivery[:status] == "accepted" }
      end
    end

    def self.to_user(user)
      Current.set(firm: user.firm, user:) do
        new(user:, session: nil).call
      end
    end

    def self.for_session(user:, session:)
      new(user:, session:).call
    end

    def initialize(user:, session:)
      @user = user
      @session = session
    end

    def call
      subscriptions = target_subscriptions.to_a
      if subscriptions.empty?
        return Result.new(ok?: false, error_code: "no_subscription",
                          error_message: "This broker has no browser registered for push.",
                          deliveries: [])
      end

      unless Vapid.configured?
        return Result.new(ok?: false, error_code: "push_not_configured",
                          error_message: "Browser push is not configured on this server.",
                          deliveries: [])
      end

      recorded = Record.call(
        user:,
        kind: "test",
        title: "Test notification",
        body: "If you can read this, browser notifications are working.",
        dedupe_key: "test:#{UuidV7.generate}",
        data: { "page" => "settings" },
        force: true,
        subscriptions:
      )

      deliveries = recorded.deliveries
      if deliveries.any? { |delivery| delivery[:status] == "accepted" }
        Result.new(ok?: true, notification: recorded.notification, deliveries:)
      else
        Result.new(
          ok?: false,
          notification: recorded.notification,
          error_code: error_code_for(deliveries),
          error_message: "The push service did not accept the test.",
          deliveries:
        )
      end
    end

    private

    attr_reader :user, :session

    def target_subscriptions
      if session
        PushSubscription.where(auth_session_id: session.id)
      else
        PushSubscription.where(user_id: user.id)
      end
    end

    def error_code_for(deliveries)
      return "push_not_configured" if deliveries.any? { |delivery| delivery[:code] == "push_not_configured" }
      return "push_key_mismatch" if deliveries.any? { |delivery| delivery[:code] == "push_key_mismatch" }

      "push_rejected"
    end
  end
end
