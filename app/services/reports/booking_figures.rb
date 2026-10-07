# frozen_string_literal: true

module Reports
  # One pass over the bookings in the window. Money sums never join invoices
  # or collections onto the booking row.
  class BookingFigures
    MONTH = "(date_trunc('month', bookings.booked_on))::date"

    def initialize(filters:, user:)
      @filters = filters
      @user = user
    end

    def by_month
      scope = booking_scope
      counts = counts_by_month(scope)
      live_ids = scope.live.select(:id)
      invoice_counts = documents_by_month(Invoice.raised.where(booking_id: live_ids), :count)
      invoice_amounts = documents_by_month(Invoice.raised.where(booking_id: live_ids), :sum)
      collection_counts = documents_by_month(Collection.where(booking_id: live_ids), :count)
      collection_amounts = documents_by_month(Collection.where(booking_id: live_ids), :sum)

      filters.window.months.map do |month|
        figures = counts.fetch(month, empty_counts)
        Catalog.month_row(month).merge(figures).merge(
          invoices: invoice_counts.fetch(month, 0),
          collections: collection_counts.fetch(month, 0),
          invoiced: invoice_amounts.fetch(month, 0),
          collected: collection_amounts.fetch(month, 0)
        )
      end
    end

    private

    attr_reader :filters, :user

    def booking_scope
      leads = filters.lead_scope(user:, money: true, created: false, status: false)
      Booking.where(lead_id: leads.select(:id), booked_on: filters.window.from_date..filters.window.upto_date)
    end

    def counts_by_month(scope)
      scope.group(Arel.sql(MONTH)).pluck(Arel.sql(<<~SQL.squish)).to_h do |month, bookings, cancelled, live, agreement, income|
        #{MONTH},
        COUNT(*),
        COUNT(*) FILTER (WHERE bookings.status = 'cancelled'),
        COUNT(*) FILTER (WHERE bookings.status = 'live'),
        COALESCE(SUM(bookings.agreement_value) FILTER (WHERE bookings.status = 'live'), 0),
        COALESCE(SUM(bookings.net_income) FILTER (WHERE bookings.status = 'live'), 0)
      SQL
        [ month.to_date, {
          bookings: bookings.to_i,
          cancelled: cancelled.to_i,
          live: live.to_i,
          agreement_value: agreement.to_i,
          net_income: income.to_i
        } ]
      end
    end

    def documents_by_month(scope, how)
      grouped = scope.joins(:booking).group(Arel.sql(MONTH))
      values = how == :count ? grouped.count : grouped.sum(:amount)
      values.transform_keys { |month| month.to_date }.transform_values(&:to_i)
    end

    def empty_counts
      { bookings: 0, cancelled: 0, live: 0, agreement_value: 0, net_income: 0 }
    end
  end
end
