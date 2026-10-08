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

  # A prospect import is a broker's own spreadsheet, not a form. These are the
  # messages shown on the row that could not be turned into one Indian mobile.
  NUMBER_REQUIRED = "A client number is required."
  SCIENTIFIC_NUMBER = "This number was saved in scientific notation. Format the column as text and enter the full number."
  NOT_A_MOBILE = "This is not an Indian mobile number."
  TOO_MANY_NUMBERS = "This cell has more than one mobile number. Keep only one."

  # Optional +91 / 0091 / trunk 0, then a 10-digit mobile starting 6–9.
  # Separators may sit between digits. The boundary check in
  # `extract_indian_mobile` rejects a match glued to more digits.
  MOBILE_TOKEN = /
    (?:(?:\+|00)?\s*91[\s.\-()]*|0)?
    [6-9](?:[\s.\-()]*\d){9}
  /x

  Extraction = Struct.new(:mobile, :error, keyword_init: true) do
    def ok? = error.nil?
  end

  class << self
    # One Indian mobile, or a reason the cell cannot be used. Lead import keeps
    # using `normalise`; this is stricter because a calling list is dialled as-is.
    def extract_indian_mobile(value)
      text = value.to_s.strip.gsub(/\A[''`]+/, "")
      return Extraction.new(error: NUMBER_REQUIRED) if text.blank?
      return Extraction.new(error: SCIENTIFIC_NUMBER) if text.match?(/\d(?:\.\d+)?[eE][+\-]?\d/)

      found = scan_mobiles(text).uniq
      return Extraction.new(error: NOT_A_MOBILE) if found.empty?
      return Extraction.new(error: TOO_MANY_NUMBERS) if found.size > 1

      Extraction.new(mobile: "+91#{found.first}")
    end

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

    private

    def scan_mobiles(text)
      found = []
      offset = 0
      while (match = MOBILE_TOKEN.match(text, offset))
        offset = match.end(0)
        before = match.begin(0).zero? ? nil : text[match.begin(0) - 1]
        after = text[match.end(0)]
        next if before&.match?(/\d/) || after&.match?(/\d/)

        mobile = interpret_mobile_digits(match[0].gsub(/\D/, ""))
        found << mobile if mobile
      end
      found
    end

    def interpret_mobile_digits(digits)
      digits = digits.sub(/\A0+/, "")
      if digits.length == 12 && digits.start_with?("91") && digits[2].match?(/[6-9]/)
        digits[2, 10]
      elsif digits.match?(/\A[6-9]\d{9}\z/)
        digits
      end
    end
  end
end
