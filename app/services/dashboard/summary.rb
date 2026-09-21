# frozen_string_literal: true

module Dashboard
  # Everything the app's home screen shows, in one request.
  #
  # It exists because the alternative was six round trips for one card: every
  # counter here is derivable from a filter the API already exposes, and the
  # mobile team was about to fan out to get them.
  #
  # Two rules this class is built around:
  #
  # 1. **Never sum over a scope carrying `includes`.** That becomes a LEFT JOIN
  #    and counts a booking once per invoice, which once reported ₹3.12 Cr
  #    against a true ₹1.56 Cr. Every total below re-selects by id, the same way
  #    BookingsController#totals_for does.
  #
  # 2. **Scope to what the caller may see.** Agents see only leads assigned to
  #    them, and may not see bookings at all — so the money block is *absent*
  #    for them rather than zeroed. A zero would read as "no revenue", which is
  #    a different and wrong statement.
  class Summary
    def initialize(user:, today: Date.current)
      @user = user
      @today = today
    end

    def call
      payload = { leads: leads_block, inventory: inventory_block, generated_at: Time.current }
      # Agents get `forbidden_role` on every booking endpoint, so the dashboard
      # does not quietly hand them the same numbers by another route.
      payload[:money] = money_block if money_visible?
      payload
    end

    private

    attr_reader :user, :today

    def money_visible? = user.super_admin? || user.manager?

    # — leads —

    def visible_leads = Lead.visible_to(user)

    # One row of counts rather than six round trips. `FILTER` is standard SQL
    # and reads closer to the intent than SUM(CASE WHEN …).
    COUNTS_SQL = <<~SQL.squish
      COUNT(*),
      COUNT(*) FILTER (WHERE lead_statuses.code = 'hot'),
      COUNT(*) FILTER (WHERE leads.next_action_at BETWEEN :day_start AND :day_end),
      COUNT(*) FILTER (WHERE leads.next_action_at < :now AND lead_statuses.is_terminal = FALSE),
      COUNT(*) FILTER (WHERE leads.first_visit_at IS NOT NULL),
      COUNT(*) FILTER (WHERE lead_statuses.code = 'new'),
      COUNT(*) FILTER (WHERE lead_statuses.code = 'visit_planned'),
      COUNT(*) FILTER (WHERE lead_statuses.code IN ('hot', 'negotiation'))
    SQL

    def leads_block
      total, hot, todays_followups, missed_followups, visited,
        new_count, visit_planned, hot_negotiation =
        visible_leads.joins(:lead_status).pick(Arel.sql(counts_select))

      recent = visible_leads
        .missed_followup
        .includes(:lead_status, :property_type, :typologies, :assigned_user, :lead_source)
        .order("leads.next_action_at ASC, leads.created_at DESC")
        .limit(3).to_a
      Lead.preload_card_extras(recent)

      {
        total: total.to_i,
        new: new_count.to_i,
        hot: hot.to_i,
        hot_negotiation: hot_negotiation.to_i,
        todays_followups: todays_followups.to_i,
        missed_followups: missed_followups.to_i,
        visit_planned: visit_planned.to_i,
        visited: visited.to_i,
        bookings: live_bookings.count,
        recent: recent.map { |lead| Api::V1::LeadSerializer.list(lead) }
      }
    end

    # Bound rather than interpolated. The values are server-derived, but a
    # timestamp built by string concatenation is how the next one stops being.
    def counts_select
      ApplicationRecord.sanitize_sql_array(
        [ COUNTS_SQL,
          { day_start: today.beginning_of_day, day_end: today.end_of_day, now: Time.current } ]
      )
    end

    # — money —

    def live_bookings = Booking.live

    # Every money tile in one query.
    #
    # The naive version — a scope per tile — cost thirteen round trips, and the
    # recent-bookings strip cost six more because BookingSerializer#list calls
    # invoiced_total, collected_total and outstanding, and `outstanding` re-runs
    # the first two. For an endpoint whose entire purpose is replacing six calls
    # with one, that was the wrong trade.
    MONEY_SQL = <<~SQL.squish
      COUNT(*)                        FILTER (WHERE status = 'live'),
      COALESCE(SUM(agreement_value)   FILTER (WHERE status = 'live'), 0),
      COALESCE(SUM(net_income)        FILTER (WHERE status = 'live'), 0),

      COUNT(*)                        FILTER (WHERE status = 'live' AND booked_on BETWEEN :ms AND :me),
      COALESCE(SUM(agreement_value)   FILTER (WHERE status = 'live' AND booked_on BETWEEN :ms AND :me), 0),
      COALESCE(SUM(net_income)        FILTER (WHERE status = 'live' AND booked_on BETWEEN :ms AND :me), 0),

      COUNT(*)                        FILTER (WHERE status = 'live' AND booked_on BETWEEN :fs AND :fe),
      COALESCE(SUM(agreement_value)   FILTER (WHERE status = 'live' AND booked_on BETWEEN :fs AND :fe), 0),
      COALESCE(SUM(net_income)        FILTER (WHERE status = 'live' AND booked_on BETWEEN :fs AND :fe), 0),

      COUNT(*)                        FILTER (WHERE status = 'live' AND registration_done_on IS NOT NULL),
      COALESCE(SUM(agreement_value)   FILTER (WHERE status = 'live' AND registration_done_on IS NOT NULL), 0),

      COUNT(*)                        FILTER (WHERE status = 'cancelled'),
      COALESCE(SUM(agreement_value)   FILTER (WHERE status = 'cancelled'), 0)
    SQL

    def money_block
      fy = FinancialYear.range(today)
      row = Booking.pick(Arel.sql(ApplicationRecord.sanitize_sql_array([
        MONEY_SQL,
        { ms: today.beginning_of_month, me: today.end_of_month, fs: fy.first, fe: fy.last }
      ])))

      count, revenue, brokerage,
        m_count, m_revenue, m_brokerage,
        f_count, f_revenue, f_brokerage,
        reg_count, reg_value,
        can_count, can_value = row.map(&:to_i)

      {
        # Gross value of what the firm has sold; brokerage is what it keeps.
        # The design's tiles say "Revenue till date" and "Brokerage earned" —
        # different numbers, both wanted.
        revenue_till_date: revenue,
        brokerage_earned: brokerage,
        bookings_count: count,

        this_month: { bookings: m_count, revenue: m_revenue, brokerage: m_brokerage },
        this_fy: {
          label: FinancialYear.label(today), starts_on: fy.first, ends_on: fy.last,
          bookings: f_count, revenue: f_revenue, brokerage: f_brokerage
        },

        registered: { count: reg_count, value: reg_value },
        # Cancelled bookings leave Booking.live, so they are counted separately
        # and deliberately excluded from every figure above.
        cancelled: { count: can_count, value: can_value },

        invoiced: invoiced_total,
        collected: collected_total,
        outstanding: invoiced_total - collected_total,

        recent: recent_bookings
      }
    end

    # The design's strip shows code, customer, value, brokerage and status —
    # nothing else. A compact row rather than BookingSerializer#list, which
    # would cost six queries per booking for figures this screen never renders.
    def recent_bookings
      Booking.live.recent_first.limit(3).includes(:lead).map do |b|
        {
          id: b.id, code: b.code, status: b.status,
          customer_name: b.customer_name,
          agreement_value: b.agreement_value,
          net_income: b.net_income,
          booked_on: b.booked_on,
          lead: { id: b.lead_id, code: b.lead&.code }
        }
      end
    end

    # Summed against the booking ids rather than through the association, so no
    # join can duplicate a row. Cancelled bookings keep their invoices on
    # record, so both are restricted to live ones to match the tiles above.
    def invoiced_total
      @invoiced_total ||= Invoice.where(status: :raised, booking_id: Booking.live.select(:id)).sum(:amount)
    end

    def collected_total
      @collected_total ||= Collection.where(booking_id: Booking.live.select(:id)).sum(:amount)
    end

    # — inventory —

    def inventory_block
      # Both property figures come off one scan; "3 new this week" sits directly
      # under the total on the design's strip, so they are always fetched together.
      total, this_week = Property.pick(Arel.sql(ApplicationRecord.sanitize_sql_array(
        [ "COUNT(*), COUNT(*) FILTER (WHERE created_at >= :since)", { since: 1.week.ago } ]
      )))

      {
        properties: total.to_i,
        properties_added_this_week: this_week.to_i,
        projects: Project.count
      }
    end
  end
end
