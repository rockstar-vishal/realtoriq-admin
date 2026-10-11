# frozen_string_literal: true

module Sites
  # Anonymous enquiry posts. A cache that cannot count refuses the call, the
  # same way inbound lead intake does. The test null store is the exception.
  class Throttle
    BODY_BYTES = 4.kilobytes
    PER_IP = 8
    PER_FIRM = 30
    IP_WINDOW = 10.minutes
    FIRM_WINDOW = 1.hour

    def self.allow?(ip:, firm_id:, request:)
      return false if ip.blank? || firm_id.blank?
      return false unless body_ok?(request)
      return false unless within?("sites:ip:#{ip}", PER_IP, IP_WINDOW)

      within?("sites:firm:#{firm_id}", PER_FIRM, FIRM_WINDOW)
    end

    def self.body_ok?(request)
      length = request.content_length
      # A missing length is how a chunked body skips the cap. Forms send one.
      length.present? && length <= BODY_BYTES && !length.negative?
    end

    def self.within?(key, limit, expires_in)
      count = Rails.cache.increment(key, 1, expires_in:)
      return count <= limit if count.is_a?(Integer)
      return true if Rails.cache.is_a?(ActiveSupport::Cache::NullStore)

      false
    rescue ActiveRecord::ActiveRecordError, ActiveSupport::Cache::DeserializationError
      false
    end
  end
end
