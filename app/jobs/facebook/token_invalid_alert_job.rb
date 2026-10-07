# frozen_string_literal: true

module Facebook
  # In-app notice and email for the worker that won claim_invalid!.
  # The dedupe key is the connection and the hour, so a repeat in the same
  # hour does not send again.
  class TokenInvalidAlertJob < TenantJob
    def perform(_firm_id, connection_id)
      connection = FacebookConnection.find_by(id: connection_id)
      return if connection.nil?

      hour = Time.current.strftime("%Y%m%d%H")
      connection.superadmin_recipients.find_each do |user|
        result = Notifications::Record.call(
          user:,
          kind: "facebook",
          title: "Facebook needs to be connected again",
          body: "New leads from #{connection.fb_user_name.presence || 'Facebook'} have stopped. Connect Facebook again.",
          dedupe_key: "fb_token_invalid:#{connection.id}:#{hour}",
          data: { "page" => "settings", "item" => "facebook" },
          force: true
        )
        next unless result.created && user.email.present?

        FacebookAlertMailer.token_invalid(user:, connection:).deliver_now
      end
    end
  end
end
