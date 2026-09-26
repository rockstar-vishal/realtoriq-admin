# frozen_string_literal: true

module Notifications
  # Writes one inbox row, then pushes it. A duplicate dedupe_key is a no-op:
  # the existing row stays, and we do not push again.
  class Record
    Result = Struct.new(:ok?, :notification, :created, :deliveries, :skipped, keyword_init: true)

    def self.call(...)
      new(...).call
    end

    def initialize(user:, kind:, title:, body:, dedupe_key:, data: {}, force: false, subscriptions: nil)
      @user = user
      @kind = kind
      @title = title
      @body = body
      @dedupe_key = dedupe_key
      @data = data
      @force = force
      @subscriptions = subscriptions
    end

    def call
      if !force && user.notification_mode == "none"
        return Result.new(ok?: true, created: false, skipped: true, deliveries: [])
      end

      notification = insert
      if notification.nil?
        return Result.new(ok?: true, created: false, skipped: false, deliveries: [])
      end

      deliveries = DeliverPush.call(notification:, subscriptions: target_subscriptions)
      Result.new(ok?: true, notification:, created: true, skipped: false, deliveries:)
    end

    private

    attr_reader :user, :kind, :title, :body, :dedupe_key, :data, :force, :subscriptions

    # nil means this dedupe_key was already written. Callers must not push again.
    def insert
      user.notifications.create!(
        firm_id: user.firm_id,
        kind:,
        title:,
        body:,
        dedupe_key:,
        data:
      )
    rescue ActiveRecord::RecordNotUnique
      nil
    end

    def target_subscriptions
      return subscriptions if subscriptions

      PushSubscription.where(user_id: user.id)
    end
  end
end
