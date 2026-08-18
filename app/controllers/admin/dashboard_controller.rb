# frozen_string_literal: true

module Admin
  class DashboardController < BaseController
    def show
      @firms_by_status = Firm.group(:status).count
      @total_firms = @firms_by_status.values.sum

      @added_this_month = Firm.where(created_at: Time.current.all_month).count

      # Firms missing at least one verified channel. A left join would be
      # cheaper but reads worse; at admin-panel scale this is fine.
      @unverified_firms = Firm.where.not(
        id: ContactChannel.verification_verified
                          .group(:firm_id)
                          .having("COUNT(*) = ?", ContactChannel::KINDS.size)
                          .select(:firm_id)
      ).count

      @expiring_subscriptions = Subscription.across_firms.expiring_within(30).count

      @recent_firms = Firm.order(created_at: :desc).limit(8)
    end
  end
end
