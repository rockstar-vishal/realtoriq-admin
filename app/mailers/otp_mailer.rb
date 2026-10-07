# frozen_string_literal: true

# Carries verification codes to the firm's email channel. SMS goes through
# MSG91 and WhatsApp through Twilio — see Notifications::OutboundDeliverer.
class OtpMailer < ApplicationMailer
  def code(destination:, code:, purpose:)
    @code = code
    @purpose = purpose

    mail(to: destination, subject: "#{code} is your RealtorIQ verification code")
  end
end
