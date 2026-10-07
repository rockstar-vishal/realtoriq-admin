# frozen_string_literal: true

module Facebook
  # One notice when a Page token dies. The login and the other Pages stay.
  class PageAttentionJob < TenantJob
    def perform(_firm_id, page_id)
      page = FacebookPage.find_by(id: page_id)
      return if page.nil?

      hour = Time.current.strftime("%Y%m%d%H")
      page.facebook_connection.superadmin_recipients.find_each do |user|
        result = Notifications::Record.call(
          user:,
          kind: "facebook",
          title: "A Facebook Page needs attention",
          body: "#{page.page_name} needs to be connected again. Your other Pages are unchanged.",
          dedupe_key: "fb_page_attention:#{page.id}:#{hour}",
          data: { "page" => "settings", "item" => "facebook" },
          force: true
        )
        next unless result.created && user.email.present?

        FacebookAlertMailer.page_needs_attention(user:, page:).deliver_now
      rescue StandardError => e
        Log.error("page_attention", page_id: page.id, error_class: e.class.name)
      end
    end
  end
end
