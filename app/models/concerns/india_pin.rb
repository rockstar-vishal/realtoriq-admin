# frozen_string_literal: true

# A map pin is optional except on the listing form. When both coordinates are
# present they have to sit inside India (lat 6–37, lng 68–98).
module IndiaPin
  extend ActiveSupport::Concern

  LAT_RANGE = 6..37
  LNG_RANGE = 68..98
  PIN_MESSAGE = "Place the pin on the map"

  def self.pin_inside_india?(lat, lng)
    lat_d = coordinate(lat)
    lng_d = coordinate(lng)
    return false if lat_d.nil? || lng_d.nil?

    LAT_RANGE.cover?(lat_d) && LNG_RANGE.cover?(lng_d)
  end

  def self.coordinate(value)
    return if value.nil?
    return if value.is_a?(String) && value.strip.empty?

    BigDecimal(value.to_s)
  rescue ArgumentError
    nil
  end

  class_methods do
    def pin_inside_india?(lat, lng)
      IndiaPin.pin_inside_india?(lat, lng)
    end

    def coordinate(value)
      IndiaPin.coordinate(value)
    end
  end

  included do
    validate :pin_is_inside_india
  end

  def has_pin?
    lat.present? && lng.present?
  end

  private

  def pin_is_inside_india
    return if lat.blank? && lng.blank?
    return if self.class.pin_inside_india?(lat, lng)

    errors.add(:base, "The pin must be inside India.")
  end
end
