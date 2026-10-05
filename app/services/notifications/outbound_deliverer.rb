# frozen_string_literal: true

module Notifications
  # Real delivery. Selected when OTP_DELIVERY is "msg91" — that value is the
  # production default, and the name stayed when WhatsApp moved off MSG91 so
  # an existing deploy keeps sending without a new environment variable.
  #
  # SMS is MSG91. WhatsApp is Twilio. Email is Action Mailer. Each transport
  # is checked on its own, so sign-in SMS works before the Twilio account
  # credentials are in place.
  class OutboundDeliverer < Deliverer
    def deliver_code(transport:, destination:, code:, purpose:)
      case transport
      when :sms
        Msg91Deliverer.new.deliver_code(transport:, destination:, code:, purpose:)
      when :whatsapp
        TwilioDeliverer.new.deliver_code(transport:, destination:, code:, purpose:)
      when :email
        OtpMailer.code(destination:, code:, purpose:).deliver_later
        true
      else
        raise DeliveryError, "Unknown transport #{transport}"
      end
    end
  end
end
