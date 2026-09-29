# frozen_string_literal: true

module Realtoriq
  # The live-lead enquiry mail. Ids only: passing the records themselves makes
  # the mail job look them up with no firm set, and FirmScoped finds nothing.
  class EnquiryMailJob < TenantJob
    def perform(_firm_id, lead_id, user_id, enquirer_name)
      user = User.find_by(id: user_id)
      lead = Lead.find_by(id: lead_id)
      return if user.nil? || lead.nil? || user.email.blank?

      MarketplaceEnquiryMailer.live_lead(user:, lead:, enquirer_name:).deliver_now
    end
  end
end
