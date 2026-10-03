# frozen_string_literal: true

module Reports
  # Rupees on the live bookings booked in each month. Invoiced, collected and
  # outstanding are the lifetime totals on those bookings, not cash that moved
  # during the month. Outstanding is invoiced minus collected.
  class Revenue
    Result = Struct.new(:ok?, :payload, :error_message, keyword_init: true)
    MONEY_KEYS = %i[agreement_value net_income invoiced collected].freeze

    def initialize(user:, params:, today: Date.current)
      @filters = Filters.new(params, today:)
      @user = user
    end

    def call
      return Result.new(ok?: false, error_message: filters.error) if filters.error

      rows = BookingFigures.new(filters:, user:).by_month.map { |row| money_row(row) }
      Result.new(ok?: true, payload: {
        from: filters.window.from_date.iso8601,
        upto: filters.window.upto_date.iso8601,
        rows:,
        summary: summarize(rows)
      })
    end

    private

    attr_reader :filters, :user

    def money_row(row)
      {
        month: row[:month],
        label: row[:label],
        agreement_value: row[:agreement_value],
        net_income: row[:net_income],
        invoiced: row[:invoiced],
        collected: row[:collected],
        outstanding: row[:invoiced] - row[:collected]
      }
    end

    def summarize(rows)
      totals = MONEY_KEYS.to_h { |key| [ key, rows.sum { |row| row[key] } ] }
      totals[:outstanding] = totals[:invoiced] - totals[:collected]
      totals
    end
  end
end
