# frozen_string_literal: true

# Carries verification codes to the firm's email channel. SMS and WhatsApp go
# through MSG91 instead — see Notifications::Msg91Deliverer.
class OtpMailer < ApplicationMailer
  def code(destination:, code:, purpose:)
    @code = code
    @purpose = purpose

    mail(to: destination, subject: "#{code} is your RealtorIQ verification code")
  end
end
