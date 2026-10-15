# frozen_string_literal: true

module Onboarding
  # Counters for code sends and submits. A cache that cannot count allows the
  # call in the test null store and refuses it everywhere else, matching
  # Sites::Throttle.
  class Throttle
    SENDS_PER_IP = 15
    SENDS_PER_SITTING = 5
    DESTINATIONS_PER_SITTING = 3
    SENDS_PER_DESTINATION = 5
    SUBMITS_PER_IP = 5

    def self.allow_send(ip:, sitting_id:, kind:, destination:)
      return :limited if ip.blank? || sitting_id.blank? || destination.blank?
      return :busy if sms?(kind) && global_capped?
      return :limited unless reserve_destination(sitting_id, kind, destination)
      return :limited unless Sites::Throttle.within?("onb:ip:#{ip}", SENDS_PER_IP, 1.hour)
      return :limited unless Sites::Throttle.within?("onb:sit:#{sitting_id}:#{kind}", SENDS_PER_SITTING, 2.hours)
      return :limited unless Sites::Throttle.within?("onb:dest:#{destination}", SENDS_PER_DESTINATION, 24.hours)

      :ok
    end

    def self.allow_submit?(ip)
      return false if ip.blank?

      Sites::Throttle.within?("onb:submit:#{ip}", SUBMITS_PER_IP, 1.hour)
    end

    def self.hourly_cap
      Integer(ENV.fetch("ONBOARDING_OTP_HOURLY_CAP", "300"))
    rescue ArgumentError, TypeError
      300
    end

    def self.sms?(kind)
      %w[mobile whatsapp].include?(kind.to_s)
    end

    def self.global_capped?
      hour = Time.current.strftime("%Y%m%d%H")
      count = Rails.cache.increment("onb:sms:#{hour}", 1, expires_in: 2.hours)
      return false unless count.is_a?(Integer)
      return false if count <= hourly_cap

      alert_once(hour, count)
      true
    end

    def self.alert_once(hour, count)
      key = "onb:sms:alert:#{hour}"
      return if Rails.cache.read(key)

      Rails.cache.write(key, true, expires_in: 2.hours)
      OnboardingMailer.otp_cap_reached(count, hourly_cap).deliver_later
    end

    def self.reserve_destination(sitting_id, kind, destination)
      key = "onb:dests:#{sitting_id}:#{kind}"
      list = Rails.cache.read(key)
      list = [] unless list.is_a?(Array)
      return true if list.include?(destination)
      return false if list.size >= DESTINATIONS_PER_SITTING

      Rails.cache.write(key, list + [ destination ], expires_in: 2.hours)
      true
    end

    private_class_method :sms?, :global_capped?, :alert_once, :reserve_destination
  end
end
