# frozen_string_literal: true

module Onboarding
  # The verify cookie. It is not an application and not a draft: a sitting id
  # for the rate limits, and a tick for each verified value.
  class Sitting
    COOKIE = :riq_verify
    TTL = 2.hours

    def initialize(cookies)
      @cookies = cookies
      raw = cookies.encrypted[COOKIE]
      @data = raw.is_a?(Hash) ? raw.deep_stringify_keys : {}
      fresh = @data["sitting_id"].blank?
      @data["sitting_id"] ||= SecureRandom.uuid
      @data["ticks"] ||= {}
      @data["sent_at"] ||= {}
      @data["codes"] ||= {}
      write if fresh
    end

    def sitting_id = @data["sitting_id"]

    # "verified", "sent" (a usable code is still waiting), or "idle".
    def state(kind, value)
      return "verified" if verified?(kind, value)
      return "sent" if reusable_code(kind, value).present?

      "idle"
    end

    # What to put back in the field: the ticked value, else the value a code
    # was sent to. The rest of the form is not remembered.
    def value(kind)
      key = kind.to_s
      @data.dig("ticks", key, "value").presence || @data.dig("codes", key, "value").presence
    end

    def verified?(kind, value)
      tick = @data.dig("ticks", kind.to_s)
      return false if tick.blank? || value.blank? || tick["value"] != value

      verified_time(kind).present? && verified_time(kind) > TTL.ago
    end

    def verified_time(kind)
      raw = @data.dig("ticks", kind.to_s, "verified_at")
      return nil if raw.blank?

      Time.zone.parse(raw.to_s)
    end

    def mark_verified!(kind, value)
      @data["ticks"][kind.to_s] = { "value" => value, "verified_at" => Time.current.iso8601(6) }
      write
    end

    def mark_sent!(kind)
      @data["sent_at"][kind.to_s] = Time.current.iso8601(6)
      write
    end

    def sent_at(kind)
      raw = @data.dig("sent_at", kind.to_s)
      return nil if raw.blank?

      Time.zone.parse(raw.to_s)
    end

    def cooling_down?(kind)
      sent = sent_at(kind)
      sent.present? && sent > ContactChannel::RESEND_COOLDOWN.ago
    end

    # The plaintext lives only in this encrypted cookie, so a resend inside the
    # code's own 10-minute life can send the same digits. The database still
    # stores a digest.
    def remember_code!(kind, destination, code)
      @data["codes"][kind.to_s] = {
        "value" => destination,
        "code" => code,
        "issued_at" => Time.current.iso8601(6)
      }
      write
    end

    def reusable_code(kind, destination)
      entry = @data.dig("codes", kind.to_s)
      return if entry.blank? || entry["value"] != destination.to_s || entry["code"].blank?

      issued = Time.zone.parse(entry["issued_at"].to_s)
      return if issued.blank? || issued <= OneTimeCode::DEFAULT_TTL.ago

      record = OneTimeCode.usable.where(purpose: "verify_#{kind}", destination:).order(created_at: :desc).first
      return unless record&.usable?

      entry["code"]
    end

    def forget!(kind)
      key = kind.to_s
      @data["ticks"].delete(key)
      @data["sent_at"]&.delete(key)
      @data["codes"]&.delete(key)
      write
    end

    # A changed number is no longer the number that was verified or sent a code.
    def sync!(values)
      changed = false
      values.each do |kind, value|
        key = kind.to_s
        tick = @data.dig("ticks", key)
        code = @data.dig("codes", key)
        next if (tick.blank? || tick["value"] == value) && (code.blank? || code["value"] == value)

        @data["ticks"].delete(key) if tick.present? && tick["value"] != value
        if code.present? && code["value"] != value
          @data["codes"].delete(key)
          @data["sent_at"]&.delete(key)
        end
        changed = true
      end
      write if changed
    end

    def clear!
      @cookies.delete(COOKIE)
    end

    def write
      expiry = latest_verification&.+(TTL) || TTL.from_now
      @cookies.encrypted[COOKIE] = {
        value: @data,
        expires: expiry,
        httponly: true,
        secure: Rails.env.production?,
        same_site: :lax
      }
    end

    private

    def latest_verification
      times = @data["ticks"].values.filter_map { |tick| Time.zone.parse(tick["verified_at"].to_s) }
      times.max
    end
  end
end
