# frozen_string_literal: true

module Reports
  # Generated is leads created in the month. Dead is distinct leads that
  # entered a dead status in the month. The two populations are not the same,
  # so the rate can exceed 100%.
  class DeadLeads
    # created_at is timestamp without time zone, holding UTC. The first
    # AT TIME ZONE reads that clock as UTC; the second prints it in Kolkata.
    # One AT TIME ZONE would treat the UTC clock as already being IST and
    # put 00:30 on 1 April into March.
    MONTH = "(date_trunc('month', (%s AT TIME ZONE 'UTC') AT TIME ZONE 'Asia/Kolkata'))::date"
    Result = Struct.new(:ok?, :payload, :error_message, keyword_init: true)

    def initialize(user:, params:, today: Date.current)
      @user = user
      @filters = Filters.new(params, today:)
    end

    def call
      return Result.new(ok?: false, error_message: filters.error) if filters.error

      generated = generated_by_month
      deaths = deaths_by_month_and_source
      sources = source_columns(deaths)
      rows = filters.window.months.map { |month| row_for(month, generated, deaths, sources) }
      summary = summarize(rows, sources)

      Result.new(ok?: true, payload: {
        from: filters.window.from_date.iso8601,
        upto: filters.window.upto_date.iso8601,
        sources:,
        rows:,
        summary:
      })
    end

    private

    attr_reader :user, :filters

    def generated_by_month
      expression = format(MONTH, "leads.created_at")
      filters.lead_scope(user:, created: true, status: true)
        .group(Arel.sql(expression))
        .count
        .transform_keys { |month| month.to_date }
    end

    def deaths_by_month_and_source
      leads = filters.lead_scope(user:, created: false, status: true)
      expression = format(MONTH, "lead_status_changes.changed_at")
      LeadStatusChange.into_dead
        .where(changed_at: filters.window.starts_at..filters.window.ends_at)
        .where(lead_id: leads.select(:id))
        .joins(:lead)
        .group(Arel.sql(expression), "leads.lead_source_id")
        .distinct
        .count(:lead_id)
        .each_with_object({}) do |((month, source_id), count), memo|
          memo[month.to_date] ||= {}
          memo[month.to_date][Catalog.source_key(source_id)] = count
        end
    end

    def source_columns(deaths)
      used = deaths.values.flat_map(&:keys).reject { |key| key == Catalog::NONE }
      selected = filters.source_ids
      include_none = selected.empty? || filters.source_missing?
      sources = Catalog.sources(used, include_none:)
      return sources if selected.empty? && !filters.source_missing?

      sources.select do |source|
        (source[:id].nil? && filters.source_missing?) || selected.include?(source[:id])
      end
    end

    def row_for(month, generated, deaths, sources)
      dead_by_source = deaths.fetch(month, {})
      by_source = sources.to_h { |source| [ Catalog.source_key(source[:id]), 0 ] }
      dead_by_source.each do |key, count|
        by_source[key] = count if by_source.key?(key)
      end
      dead = by_source.values.sum
      made = generated.fetch(month, 0)
      Catalog.month_row(month).merge(
        generated: made,
        dead:,
        rate: Catalog.rate(dead, made),
        by_source:
      )
    end

    def summarize(rows, sources)
      generated = rows.sum { |row| row[:generated] }
      by_source = sources.to_h { |source| [ Catalog.source_key(source[:id]), 0 ] }
      rows.each do |row|
        row[:by_source].each { |key, count| by_source[key] += count }
      end
      dead = by_source.values.sum
      { generated:, dead:, rate: Catalog.rate(dead, generated), by_source: }
    end
  end
end
