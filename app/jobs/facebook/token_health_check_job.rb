# frozen_string_literal: true

module Facebook
  # Weekly check of every active connection. Each firm runs in its own job.
  class TokenHealthCheckJob < ApplicationJob
    def perform
      FacebookConnection.across_firms.where(status: "active").find_each do |connection|
        TokenHealthCheckFirmJob.perform_later(connection.firm_id, connection.id)
      end
    end
  end

  class TokenHealthCheckFirmJob < TenantJob
    def perform(_firm_id, connection_id)
      connection = FacebookConnection.find_by(id: connection_id)
      return unless connection&.connection_active?

      healthy = TokenManager.health_check!(connection)
      warn_expiring(connection) if healthy && connection.user_access? && connection.token_expiring_soon?
    rescue StandardError => e
      Log.error("token_health", connection_id:, error_class: e.class.name)
    end

    private

    def warn_expiring(connection)
      days_left = ((connection.token_expires_at - Time.current) / 1.day).ceil
      days_left = 1 if days_left < 1
      connection.superadmin_recipients.find_each do |user|
        Notifications::Record.call(
          user:,
          kind: "facebook",
          title: "Facebook access expires soon",
          body: "Reconnect Facebook in the next #{days_left} #{"day".pluralize(days_left)} so new leads keep coming in.",
          dedupe_key: "fb_token_expiring:#{connection.id}:#{days_left}",
          data: { "page" => "settings", "item" => "facebook" },
          force: true
        )
      end
    end
  end
end
