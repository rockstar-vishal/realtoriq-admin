# frozen_string_literal: true

module Inbound
  # Stops a flood before it becomes leads or inbox rows.
  #
  # The bucket is the caller's address, or a key we have already accepted.
  # A bearer token we do not recognise must not get a bucket of its own:
  # inventing a new token on every request would never cross the line, and
  # would write a cache row per attempt.
  #
  # A cache that cannot count refuses the call. The test null store is the
  # exception, so the rest of the suite is not a rate-limit test.
  class Throttle
    BODY_BYTES = 8.kilobytes
    PER_IP = 300
    FAILED_AUTHS = 20
    PER_KEY = 30
    FAILURE_NOTICES = 10
    WINDOW = 1.minute
    NOTICE_WINDOW = 26.hours

    def self.cache
      Rails.cache
    end

    def self.body_within_limit?(request)
      declared = request.content_length
      return false if declared && declared > BODY_BYTES

      io = request.body
      return true if io.nil?

      too_big = if io.respond_to?(:size)
        io.size > BODY_BYTES
      else
        sample = io.read(BODY_BYTES + 1)
        sample && sample.bytesize > BODY_BYTES
      end
      io.rewind if io.respond_to?(:rewind)
      !too_big
    end

    def self.allow_ip?(ip)
      return false if ip.blank?
      return false if failed_count(ip) >= FAILED_AUTHS

      within?(cache, "inbound:ip:#{ip}", PER_IP, WINDOW)
    end

    def self.record_failure(ip)
      return if ip.blank?

      cache.increment("inbound:fail:#{ip}", 1, expires_in: WINDOW)
    rescue ActiveRecord::ActiveRecordError
      nil
    end

    def self.allow_key?(digest)
      return false if digest.blank?

      within?(cache, "inbound:key:#{digest}", PER_KEY, WINDOW)
    end

    # True when this firm may still be told about a rejected enquiry today.
    # The counter moves only after a row is actually inserted, so a portal
    # retrying the same rejection does not use up the day's notices.
    def self.failure_notices_left?(firm_id)
      cache.read(notice_key(firm_id)).to_i < FAILURE_NOTICES
    rescue ActiveRecord::ActiveRecordError, ActiveSupport::Cache::DeserializationError
      false
    end

    def self.record_failure_notice(firm_id)
      cache.increment(notice_key(firm_id), 1, expires_in: NOTICE_WINDOW)
    rescue ActiveRecord::ActiveRecordError
      nil
    end

    def self.notice_key(firm_id)
      day = Time.find_zone(Lead::NCD_ZONE).today.iso8601
      "inbound:notice:#{firm_id}:#{day}"
    end

    def self.failed_count(ip)
      cache.read("inbound:fail:#{ip}").to_i
    rescue ActiveRecord::ActiveRecordError, ActiveSupport::Cache::DeserializationError
      FAILED_AUTHS
    end

    def self.within?(store, key, limit, expires_in)
      count = store.increment(key, 1, expires_in:)
      return count <= limit if count.is_a?(Integer)
      return true if store.is_a?(ActiveSupport::Cache::NullStore)

      false
    rescue ActiveRecord::ActiveRecordError, ActiveSupport::Cache::DeserializationError
      false
    end

    private_class_method :failed_count, :within?, :notice_key
  end
end
