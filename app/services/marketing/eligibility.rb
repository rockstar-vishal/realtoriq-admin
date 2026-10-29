# frozen_string_literal: true

module Marketing
  # A creative or a kit always prints the firm's RERA number and a verified
  # phone. The titles the app shows live with the codes; the API sends the body.
  module Eligibility
    MESSAGES = {
      "firm_rera_missing" => "It's printed on every creative and kit you share, as MahaRERA requires. Ask your RealtorIQ RM to add it.",
      "firm_phone_missing" => "Creatives carry your firm's verified mobile or WhatsApp number."
    }.freeze

    def self.reason(firm)
      return "firm_rera_missing" if firm.nil? || firm.rera_number.blank?

      contacts = FirmContacts.new(firm)
      return "firm_phone_missing" if contacts.mobile.blank? && contacts.whatsapp.blank?

      nil
    end

    def self.payload(firm)
      blocked = reason(firm)
      { can_share: blocked.nil?, blocked_reason: blocked }
    end
  end
end
