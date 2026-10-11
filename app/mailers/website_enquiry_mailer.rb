# frozen_string_literal: true

class WebsiteEnquiryMailer < ApplicationMailer
  def enquiry(user:, lead:, enquirer_name:)
    @lead = lead
    @enquirer_name = enquirer_name.to_s.delete("\u0000").tr("\r\n", " ").strip.presence || "A client"

    mail(to: user.email, subject: "Website enquiry on #{lead.code}")
  end
end
