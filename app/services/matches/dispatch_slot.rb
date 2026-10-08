# frozen_string_literal: true

module Matches
  # Hourly. Firms whose slot is this IST hour, and whose list is older than
  # about 11 hours, get one curate job. A firm that already has a list and
  # missed its hour is caught up once that list is older than 13 hours.
  # A firm with no list yet still waits for its own hour.
  # From 08:00 to 21:00, night finds that are still waiting go out — spread
  # across the 08:00 hour, immediately after that. A lapsed firm is dropped
  # from that queue without a ping.
  class DispatchSlot
    BATCH = 1_000

    def self.call
      new.call
    end

    def call
      now = Slot.now
      enqueue_firms(now)
      enqueue_releases(now) if Slot.daytime?(now)
    end

    private

    def enqueue_firms(now)
      slot = now.hour % Slot::SPAN
      fresh = MatchDigest.across_firms.where(generated_at: Slot::FRESH_FOR.ago..).pluck(:firm_id).to_set
      overdue = MatchDigest.across_firms.where(generated_at: ..Slot::OVERDUE_AFTER.ago).pluck(:firm_id).to_set
      due = Eligible.firms.pluck(:id).select do |firm_id|
        next false if fresh.include?(firm_id)

        Slot.for_firm(firm_id) == slot || overdue.include?(firm_id)
      end

      due.each_slice(BATCH) do |ids|
        ActiveJob.perform_all_later(ids.map { |firm_id| CurateFirmJob.new(firm_id) })
      end
    end

    def enqueue_releases(now)
      pending_ids = MatchDigest.across_firms.where(notification_pending: true).pluck(:firm_id)
      eligible = Eligible.firms.where(id: pending_ids).pluck(:id)
      drop = pending_ids - eligible
      if drop.any?
        MatchDigest.across_firms.where(firm_id: drop).update_all(notification_pending: false, updated_at: Time.current)
      end

      eligible.each do |firm_id|
        delay = now.hour == Slot::DAY_START ? Slot.release_delay(firm_id, now) : 0.minutes
        if delay.zero?
          ReleaseDigestJob.perform_later(firm_id)
        else
          ReleaseDigestJob.set(wait: delay).perform_later(firm_id)
        end
      end
    end
  end
end
