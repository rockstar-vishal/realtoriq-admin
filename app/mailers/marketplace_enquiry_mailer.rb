# frozen_string_literal: true

class MarketplaceEnquiryMailer < ApplicationMailer
  def live_lead(user:, lead:, enquirer_name:)
    @lead = lead
    @enquirer_name = enquirer_name.presence || "A client"

    mail(to: user.email, subject: "Marketplace enquiry on #{lead.code}")
  end
end
