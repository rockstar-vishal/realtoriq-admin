# frozen_string_literal: true

module Form6
  # A MahaRERA half-year. April–September is due on 20 October. October–March
  # is due on 20 April. The id is the month the half starts: "2026-04", "2025-10".
  class Period
    attr_reader :id, :from, :to, :due_on

    def initialize(id:, from:, to:, due_on:)
      @id = id
      @from = from
      @to = to
      @due_on = due_on
    end

    def self.parse(value)
      match = value.to_s.match(/\A(\d{4})-(04|10)\z/)
      return nil unless match

      year = match[1].to_i
      return nil unless year.between?(2000, 2100)

      if match[2] == "04"
        new(id: format("%d-04", year), from: Date.new(year, 4, 1), to: Date.new(year, 9, 30),
            due_on: Date.new(year, 10, 20))
      else
        new(id: format("%d-10", year), from: Date.new(year, 10, 1), to: Date.new(year + 1, 3, 31),
            due_on: Date.new(year + 1, 4, 20))
      end
    end

    def self.containing(date)
      if date.month >= 10
        parse(format("%d-10", date.year))
      elsif date.month <= 3
        parse(format("%d-10", date.year - 1))
      else
        parse(format("%d-04", date.year))
      end
    end

    # Newest completed half first. A half is completed the day after it ends,
    # so 30 September is still the April half and 1 October reports it.
    def self.completed(limit: 6, today: Date.current)
      period = containing(today)
      period = period.previous unless period.ended?(today)
      limit.times.map do
        current = period
        period = period.previous
        current
      end
    end

    def ended?(today = Date.current) = to < today

    def previous
      start = from.month == 4 ? format("%d-10", from.year - 1) : format("%d-04", from.year)
      self.class.parse(start)
    end

    def filename_part
      if from.month == 4
        "Apr-Sep-#{from.year}"
      else
        "Oct-#{from.year}-Mar-#{to.year}"
      end
    end

    def as_json(*)
      { id:, from: from.iso8601, to: to.iso8601, due_on: due_on.iso8601 }
    end
  end
end
