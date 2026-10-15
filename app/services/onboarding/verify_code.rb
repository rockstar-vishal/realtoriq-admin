# frozen_string_literal: true

module Onboarding
  class VerifyCode
    Result = Struct.new(:ok, :message, keyword_init: true)

    def initialize(kind:, form:, sitting:)
      @kind = kind.to_s
      @form = form
      @sitting = sitting
    end

    def call
      form.normalise
      value = form.public_send(kind)
      return result(false, format_message) unless well_formed?(value)

      record = OneTimeCode.usable.where(purpose: "verify_#{kind}", destination: value).order(created_at: :desc).first
      return result(false, "That code isn't right or it has expired.") if record.nil?

      if record.verify(form.code_for(kind))
        sitting.mark_verified!(kind, value)
        return result(true, "Verified.")
      end

      left = record.max_attempts - record.reload.attempts
      if left <= 0
        result(false, "That code isn't right. Request a new one.")
      else
        result(false, "That code isn't right. #{left} #{'attempt'.pluralize(left)} left.")
      end
    end

    private

    attr_reader :kind, :form, :sitting

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
  end
end
