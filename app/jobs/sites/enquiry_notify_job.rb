# frozen_string_literal: true

module Sites
  class EnquiryNotifyJob < TenantJob
    # The arguments include the visitor's name.
    self.log_arguments = false

    def perform(_firm_id, lead_id, user_id, enquirer_name, listing_name, outcome, dedupe_key)
      user = User.find_by(id: user_id)
      lead = Lead.find_by(id: lead_id)
      return if user.nil? || lead.nil? || dedupe_key.blank?

      title = outcome == "created" ? "New website enquiry" : "Website enquiry on #{lead.code}"
      result = Notifications::Record.call(
        user:,
        kind: "website_enquiry",
        title:,
        body: [ enquirer_name.presence || "A client", listing_name.presence ].compact.join(" · "),
        dedupe_key:,
        data: { "page" => "leads", "item" => lead.id }
      )
      # A second run finds the row and does not send again. If the send itself
      # fails, drop the row so the retry can write it and try the email again.
      # notification_mode "none" writes no row, so there is no email either.
      return if user.email.blank? || !result.created

      begin
        WebsiteEnquiryMailer.enquiry(user:, lead:, enquirer_name:).deliver_now
      rescue StandardError
        result.notification.destroy if result.notification&.persisted?
        raise
      end
    end
  end
end
