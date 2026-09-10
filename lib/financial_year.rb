# frozen_string_literal: true

# The Indian financial year: 1 April to 31 March.
#
# Lives in lib/ rather than in the dashboard because the four report shapes in
# docs/schema.md are all "by FY month", and every one of them needs the same
# boundary. Getting it wrong is quiet — a January booking counted into the wrong
# year still looks like a plausible number.
module FinancialYear
  START_MONTH = 4

  class << self
    # The year an FY is named by. FY 2026-27 starts 1 Apr 2026, so any date from
    # April onwards belongs to that calendar year; January to March belongs to
    # the year before.
    def year_of(date)
      date.month >= START_MONTH ? date.year : date.year - 1
    end

    def starts_on(date) = Date.new(year_of(date), START_MONTH, 1)

    def ends_on(date) = starts_on(date).next_year - 1

    def range(date) = starts_on(date)..ends_on(date)

    # "2026-27" — how a broker writes it.
    def label(date)
      y = year_of(date)
      "#{y}-#{format('%02d', (y + 1) % 100)}"
    end
  end
end
