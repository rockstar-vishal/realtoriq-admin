# frozen_string_literal: true

module Onboarding
  class SendCode
    Result = Struct.new(:ok, :message, keyword_init: true)

    def initialize(kind:, form:, sitting:, request:)
      @kind = kind.to_s
      @form = form
      @sitting = sitting
      @request = request
    end

    def call
      form.normalise
      value = form.public_send(kind)
      return result(false, format_message) unless well_formed?(value)

      sitting.sync!(kind => value)
      return result(false, Onboarding::ALREADY_VERIFIED) if sitting.verified?(kind, value)

      conflict = conflict_message(value)
      return result(false, conflict) if conflict
      return result(false, Onboarding::WAIT) if sitting.cooling_down?(kind)

      case Throttle.allow_send(ip: request.remote_ip, sitting_id: sitting.sitting_id, kind:, destination: value)
      when :busy then return result(false, Onboarding::BUSY)
      when :limited then return result(false, Onboarding::TOO_MANY)
      end

      code = sitting.reusable_code(kind, value)
      unless code
        _record, code = OneTimeCode.issue!(
          purpose: "verify_#{kind}", destination: value, ip: request.remote_ip
        )
        sitting.remember_code!(kind, value, code)
      end
      Notifications::Deliverer.current.deliver_code(
        transport:, destination: value, code:, purpose: "verify_#{kind}"
      )
      sitting.mark_sent!(kind)
      result(true, "Code sent.")
    rescue Notifications::Deliverer::DeliveryError
      Rails.logger.warn("[onboarding] code delivery failed (#{kind})")
      result(false, Onboarding::DELIVERY_FAILED)
    end

    private

    attr_reader :kind, :form, :sitting, :request

    def result(ok, message) = Result.new(ok:, message:)

    def well_formed?(value)
      if kind == "email"
        value.to_s.match?(URI::MailTo::EMAIL_REGEXP)
      else
        value.to_s.match?(Onboarding::INDIAN_MOBILE)
      end
    end

    def format_message
      kind == "email" ? "Enter a valid email address." : "Enter an Indian mobile number."
    end

    def conflict_message(value)
      if kind == "email"
        return Onboarding::REGISTERED_EMAIL if User.across_firms.where("lower(email) = ?", value).exists?
        return Onboarding::UNDER_REVIEW_EMAIL if OnboardingApplication.across_firms.submitted.where("lower(email) = ?", value).exists?
      else
        return Onboarding::REGISTERED_NUMBER if User.across_firms.exists?(mobile: value)

        column = kind == "whatsapp" ? :whatsapp : :mobile
        if OnboardingApplication.across_firms.submitted.exists?(column => value)
          return Onboarding::UNDER_REVIEW_NUMBER
        end
      end
      nil
    end

    def transport
      case kind
      when "email" then :email
      when "whatsapp" then :whatsapp
      else :sms
      end
    end
  end
end
