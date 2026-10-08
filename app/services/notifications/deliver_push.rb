# frozen_string_literal: true

module Notifications
  # Sends one inbox row to a set of browser subscriptions. Inline on purpose:
  # development has no queue database, and a queued send reports success while
  # nothing leaves the process.
  #
  # Never log the endpoint, the keys, or the payload. The endpoint alone is
  # enough to deliver a push.
  class DeliverPush
    DEFAULT_TTL = 60 * 60

    def self.call(notification:, subscriptions:, ttl: DEFAULT_TTL)
      new(notification:, subscriptions:, ttl:).call
    end

    def initialize(notification:, subscriptions:, ttl: DEFAULT_TTL)
      @notification = notification
      @subscriptions = subscriptions
      @ttl = ttl
    end

    def call
      return [ { status: "rejected", code: "push_not_configured" } ] unless Vapid.configured?

      subscriptions.map { |subscription| deliver_one(subscription) }
    end

    private

    attr_reader :notification, :subscriptions, :ttl

    def deliver_one(subscription)
      WebPush.payload_send(
        message: payload,
        endpoint: subscription.endpoint,
        p256dh: subscription.p256dh,
        auth: subscription.auth_key,
        vapid: {
          subject: Vapid.subject,
          public_key: Vapid.public_key,
          private_key: Vapid.private_key
        },
        ttl: ttl
      )
      subscription.update!(last_success_at: Time.current, failure_count: 0)
      { status: "accepted" }
    rescue WebPush::ExpiredSubscription, WebPush::InvalidSubscription
      drop(subscription)
    rescue WebPush::ResponseError => e
      code = e.response&.code.to_i
      if [ 404, 410 ].include?(code)
        drop(subscription)
      elsif code == 401
        note_failure(subscription)
        { status: "rejected", code: "push_key_mismatch" }
      else
        note_failure(subscription)
        { status: "rejected", code: "push_rejected" }
      end
    rescue StandardError
      note_failure(subscription)
      { status: "rejected", code: "push_unreachable" }
    end

    def drop(subscription)
      subscription.destroy!
      { status: "gone" }
    end

    def note_failure(subscription)
      subscription.update!(failure_count: subscription.failure_count + 1)
    end

    def payload
      body = {
        title: notification.title,
        body: notification.body,
        notification_id: notification.id
      }
      path = Target.url(notification.data)
      body[:path] = path if path
      body.to_json
    end
  end
end
