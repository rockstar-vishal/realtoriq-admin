# frozen_string_literal: true

module Reports
  # Inclusive Asia/Kolkata calendar days. A timestamp just after midnight IST
  # belongs to that day, not to the previous UTC date.
  class Window
    ZONE = "Asia/Kolkata"
    DATE = /\A\d{4}-\d{2}-\d{2}\z/
    INVALID = "Dates must be YYYY-MM-DD, and from must be on or before upto."

    def self.zone = Time.find_zone(ZONE)

    def self.date?(value)
      text = value.to_s.strip
      return false unless DATE.match?(text)

      Date.iso8601(text)
      true
    rescue Date::Error
      false
    end

    # nil when both sides are blank. The caller decides whether that means
    # "no filter" or "use the default window".
    def self.time_range(from, upto)
      return nil if from.blank? && upto.blank?
      return nil unless from.blank? || date?(from)
      return nil unless upto.blank? || date?(upto)

      start_at = from.present? ? zone.parse(from.to_s).beginning_of_day : nil
      end_at = upto.present? ? zone.parse(upto.to_s).end_of_day : nil
      if start_at && end_at
        start_at..end_at
      elsif start_at
        start_at..
      else
        ..end_at
      end
    end

    def initialize(from:, upto:, today: Date.current)
      @raw_from = from
      @raw_upto = upto
      @today = today
    end

    def error
      return nil if raw_from.blank? && raw_upto.blank?
      return INVALID unless self.class.date?(raw_from) && self.class.date?(raw_upto)
      return INVALID if from_date > upto_date

      nil
    end

    def from_date
      return default_from if raw_from.blank? && raw_upto.blank?

      Date.iso8601(raw_from.to_s)
    end

    def upto_date
      return today if raw_from.blank? && raw_upto.blank?

      Date.iso8601(raw_upto.to_s)
    end

    def starts_at = self.class.zone.parse(from_date.iso8601).beginning_of_day

    def ends_at = self.class.zone.parse(upto_date.iso8601).end_of_day

    def months
      cursor = from_date.beginning_of_month
      last = upto_date.beginning_of_month
      list = []
      while cursor <= last
        list << cursor
        cursor = cursor.next_month
      end
      list
    end

    private

    attr_reader :raw_from, :raw_upto, :today

    def default_from = today - 29
  end
end
