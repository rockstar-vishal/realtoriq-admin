# frozen_string_literal: true

# Carpet and plot area, converted to square feet once, half-up, as a whole
# number. Factors stay BigDecimal; nothing here goes through Float.
module AreaUnits
  CODES = %w[sqft sqyd sqm guntha acre hectare].freeze
  FACTORS = {
    "sqft" => BigDecimal("1"),
    "sqyd" => BigDecimal("9"),
    "sqm" => BigDecimal("10.7639"),
    "guntha" => BigDecimal("1089"),
    "acre" => BigDecimal("43560"),
    "hectare" => BigDecimal("107639.104")
  }.freeze
  LABELS = {
    "sqft" => "sq ft",
    "sqyd" => "sq yd",
    "sqm" => "sq m",
    "guntha" => "guntha",
    "acre" => "acre",
    "hectare" => "hectare"
  }.freeze

  def self.to_sqft(value, unit)
    factor = FACTORS.fetch(unit)
    (value.to_d * factor).round(0, :half_up).to_i
  end

  # "2.50" is shown as "2.5", and "2.00" as "2". Nil stays nil.
  def self.display_quantity(value)
    return if value.nil?

    value.to_d.to_s("F").sub(/\.?0+\z/, "")
  end

  def self.reference
    CODES.map { |code|
      { code:, label: LABELS.fetch(code), sqft: FACTORS.fetch(code).to_s("F") }
    }
  end
end
