# frozen_string_literal: true

module Matches
  # Sends a night find that was saved without a ping. Safe to run twice: the
  # notification dedupe key absorbs the second push.
  class ReleaseDigest
    def self.call(firm:)
      new(firm:).call
    end

    def initialize(firm:)
      @firm = firm
    end

    def call
      return unless Current.firm_id == firm.id

      # Same row lock as CurateFirm#save. A scan that finishes after this
      # release must see the flag already cleared, and this release must not
      # write an older fingerprint over a list the scan just sent. The push
      # goes out after the commit, so a duplicate inbox row cannot roll the
      # flag back to pending.
      released = nil
      MatchDigest.transaction do
        digest = MatchDigest.lock.find_by(firm_id: firm.id)
        next unless digest&.notification_pending
        next clear(digest) unless Eligible.firm?(firm)
        next clear(digest) if digest.lead_items.blank? && digest.listing_items.blank?

        digest.update!(notification_pending: false, notified_fingerprint: digest.fingerprint)
        released = digest
      end
      deliver(released) if released
    end

    private

    attr_reader :firm

    def clear(digest)
      digest.update!(notification_pending: false)
      digest
    end

    def deliver(digest)
      Notify.call(digest:)
    rescue StandardError => error
      Rails.logger.error("[matches] notify failed for firm #{digest.firm_id}: #{error.class}: #{error.message}")
    end
  end
end
