# frozen_string_literal: true

module Realtoriq
  # In-app row and push for the broker who owns the lead. Ids only: a job has
  # no tenant until TenantJob sets one, and FirmScoped would otherwise miss
  # the user and the lead.
  class EnquiryNotifyJob < TenantJob
    def perform(_firm_id, lead_id, user_id, enquiry_id, enquirer_name, project_name, outcome)
      user = User.find_by(id: user_id)
      lead = Lead.find_by(id: lead_id)
      return if user.nil? || lead.nil?

      title = if outcome == "created"
        "New marketplace enquiry"
      else
        "Marketplace enquiry on #{lead.code}"
      end
      Notifications::Record.call(
        user:,
        kind: "marketplace_enquiry",
        title:,
        body: [ enquirer_name.presence || "A client", project_name.presence ].compact.join(" · "),
        dedupe_key: "marketplace_enquiry:#{enquiry_id}",
        data: { "page" => "leads", "item" => lead.id }
      )
    end
  end
end
