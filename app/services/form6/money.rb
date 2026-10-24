# frozen_string_literal: true

module Form6
  # Indian grouping, without the rupee sign. 752000 is "7,52,000".
  module Money
    module_function

    def group(amount)
      number = amount.to_i
      digits = number.abs.to_s
      formatted = if digits.length <= 3
        digits
      else
        head = digits[0...-3].reverse.gsub(/(\d{2})(?=\d)/, "\\1,").reverse
        "#{head},#{digits[-3..]}"
      end
      number.negative? ? "-#{formatted}" : formatted
    end
  end
end
