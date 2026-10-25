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
    before_save :forget_approximate_pin_when_it_moves
  end

  def has_pin?
    lat.present? && lng.present?
  end

  private

  # The centre pin is only a stand-in. Moving either coordinate means the
  # broker placed a real spot, so the flag cannot survive that save. A save
  # that leaves both coordinates where they are keeps it. update_columns
  # (the one-off rake) does not come through here.
  def forget_approximate_pin_when_it_moves
    return unless has_attribute?(:pin_approximate)
    return unless will_save_change_to_lat? || will_save_change_to_lng?

    self.pin_approximate = false
  end

  def pin_is_inside_india
    return if lat.blank? && lng.blank?
    return if self.class.pin_inside_india?(lat, lng)

    errors.add(:base, "The pin must be inside India.")
  end
end
