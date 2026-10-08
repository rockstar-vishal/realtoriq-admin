# frozen_string_literal: true

module Matches
  # Who gets a curated list. Same gate as the app: an active firm, not the
  # review demo, with a live subscription whose period has not ended.
  # A lapsed firm cannot open Matches, so it is not scanned and not pinged.
  module Eligible
    module_function

    def firm?(firm)
      firm.active? && !firm.review_demo? && entitled?(firm)
    end

    def firms
      Firm.where(status: "active", review_demo: false).where(id: entitled_ids)
    end

    def entitled?(firm)
      firm.subscriptions
        .where(status: Subscription::LIVE_STATUSES)
        .exists?(current_period_end: Date.current..)
    end

    def entitled_ids
      Subscription.across_firms
        .where(status: Subscription::LIVE_STATUSES)
        .where(current_period_end: Date.current..)
        .select(:firm_id)
    end
  end
end
