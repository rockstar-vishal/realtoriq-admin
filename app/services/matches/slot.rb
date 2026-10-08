# frozen_string_literal: true

module Matches
  # Which hour a firm is scanned, in India. SHA256 so the hour stays put
  # across process boots. Ruby's String#hash does not.
  module Slot
    ZONE = "Asia/Kolkata"
    SPAN = 12
    FRESH_FOR = 11.hours
    # A saved list older than this missed its hour. The next hourly run
    # catches it up. A firm with no list yet still waits for its own hour,
    # so the first rollout stays spread across the day.
    OVERDUE_AFTER = 13.hours
    DAY_START = 8
    DAY_END = 21

    module_function

    def for_firm(firm_id)
      Digest::SHA256.hexdigest(firm_id.to_s).hex % SPAN
    end

    def release_minute(firm_id)
      Digest::SHA256.hexdigest("release:#{firm_id}").hex % 60
    end

    # Minutes until this firm's morning ping, once the 08:00 dispatcher runs.
    # A later catch-up passes delay 0.
    def release_delay(firm_id, time = now)
      remaining = release_minute(firm_id) - time.min
      remaining.positive? ? remaining.minutes : 0.minutes
    end

    def now
      Time.current.in_time_zone(ZONE)
    end

    def quiet?(time = now)
      hour = time.hour
      hour >= DAY_END || hour < DAY_START
    end

    def daytime?(time = now)
      !quiet?(time)
    end
  end
end
