# frozen_string_literal: true

# Normalises Indian mobile numbers to E.164 so that the globally-unique index on
# users.mobile actually means something. Without this, "98201 44210",
# "+91 98201 44210" and "09820144210" would be three different users.
#
# Deliberately narrow: this app is India-only today. If that changes, swap this
# for a real library (phonelib) rather than growing more special cases here.
module Phone
  DEFAULT_DIALLING_CODE = "91"
  INDIAN_MOBILE_LENGTH = 10

  class << self
    # Returns an E.164 string, or the input unchanged when it can't be parsed —
    # so the model's format validation is what reports the problem, not this.
    def normalise(value)
      return nil if value.blank?

      digits = value.to_s.gsub(/\D/, "")
      return value.to_s.strip if digits.empty?

      # Trunk prefix: 09820144210 is how the number is dialled domestically.
      digits = digits.sub(/\A0+/, "")

      digits = "#{DEFAULT_DIALLING_CODE}#{digits}" if digits.length == INDIAN_MOBILE_LENGTH

      "+#{digits}"
    end

    # For display: +919820144210 → +91 98201 44210
    def format_for_display(value)
      normalised = normalise(value)
      return value.to_s if normalised.blank?

      match = normalised.match(/\A\+(\d{2})(\d{5})(\d{5})\z/)
      return normalised unless match

      "+#{match[1]} #{match[2]} #{match[3]}"
    end

    # Masks the middle of a number for the "code sent to +91 98201 44xxx" copy
    # on the OTP screen, so a shoulder-surfer can't read the full number.
    def mask(value)
      normalised = normalise(value)
      return "" if normalised.blank?
      return normalised if normalised.length < 6

      "#{normalised[0..-4]}xxx"
    end
  end
end
