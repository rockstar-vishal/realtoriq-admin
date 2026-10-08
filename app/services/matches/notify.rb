# frozen_string_literal: true

module Matches
  # Tells the firm's active super admin. A missing or disabled super admin, or
  # notification_mode none, writes nothing. The caller still marks the digest
  # so the same list is not retried.
  class Notify
    def self.call(digest:)
      new(digest:).call
    end

    def initialize(digest:)
      @digest = digest
    end

    def call
      user = digest.firm.super_admin
      return if user.nil? || !user.active?

      Notifications::Record.call(
        user:,
        kind: "match_digest",
        title:,
        body:,
        dedupe_key: "match_digest:#{digest.fingerprint}",
        data: { page: "matches" }
      )
    end

    private

    attr_reader :digest

    # No client name, budget, or locality. Those stay on the Matches page.
    # A lock screen should not show who the client is.
    def title
      "New matches are ready"
    end

    def body
      parts = []
      if lead_new.positive?
        parts << "#{lead_new} #{lead_new == 1 ? "lead has" : "leads have"} new options"
      end
      if listing_new.positive?
        parts << "#{listing_new} #{listing_new == 1 ? "listing has" : "listings have"} new buyers"
      end
      parts.join(" · ").presence || "Open Matches to see the latest list."
    end

    def lead_new
      @lead_new ||= Array(digest.lead_items).count { |item| item["new_count"].to_i.positive? }
    end

    def listing_new
      @listing_new ||= Array(digest.listing_items).count { |item| item["new_count"].to_i.positive? }
    end
  end
end
