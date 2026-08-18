# frozen_string_literal: true

module Notifications
  # How a one-time code reaches a person.
  #
  # The interface exists so the whole auth flow is exercisable end to end
  # without an MSG91 account: development and test resolve to LogDeliverer,
  # which writes the code to the Rails log. Nothing about sign-in is blocked on
  # vendor onboarding or DLT template approval.
  class Deliverer
    class DeliveryError < StandardError; end

    # Transports: :sms and :whatsapp go to MSG91, :email through Action Mailer.
    def self.current
      @current ||= build
    end

    # Lets specs substitute a spy without touching global config.
    class << self
      attr_writer :current
    end

    def self.build
      case Rails.configuration.x.otp_delivery.to_s
      when "msg91" then Msg91Deliverer.new
      else LogDeliverer.new
      end
    end

    def deliver_code(transport:, destination:, code:, purpose:)
      raise NotImplementedError
    end
  end
end
