# frozen_string_literal: true

module Reports
  # Counts of bookings whose booked_on falls in the window, plus how many
  # invoices and collections sit on the live ones.
  class Bookings
    Result = Struct.new(:ok?, :payload, :error_message, keyword_init: true)
    COUNT_KEYS = %i[bookings cancelled live agreement_value invoices collections].freeze

    def initialize(user:, params:, today: Date.current)
      @filters = Filters.new(params, today:)
      @user = user
    end

    def call
      return Result.new(ok?: false, error_message: filters.error) if filters.error

      rows = BookingFigures.new(filters:, user:).by_month.map { |row| row.except(:net_income, :invoiced, :collected) }
      Result.new(ok?: true, payload: {
        from: filters.window.from_date.iso8601,
        upto: filters.window.upto_date.iso8601,
        rows:,
        summary: COUNT_KEYS.to_h { |key| [ key, rows.sum { |row| row[key] } ] }
      })
    end

    private

    attr_reader :filters, :user
  end
end
