# frozen_string_literal: true

module Reports
  # Leads created in the window, grouped by current source and current status.
  class SourceStatus
    Result = Struct.new(:ok?, :payload, :error_message, keyword_init: true)

    def initialize(user:, params:, today: Date.current)
      @user = user
      @filters = Filters.new(params, today:)
    end

    def call
      return Result.new(ok?: false, error_message: filters.error) if filters.error

      scope = filters.lead_scope(user:, created: true, status: true)
      grouped = scope.group(:lead_source_id, :lead_status_id).count
      statuses = columns_for(grouped)
      sources = rows_for(grouped)
      counts_by_source = tally(grouped, statuses)

      rows = sources.map do |source|
        counts = counts_by_source.fetch(Catalog.source_key(source[:id]), empty_counts(statuses))
        { source:, counts:, total: counts.values.sum }
      end

      summary_counts = empty_counts(statuses)
      rows.each { |row| row[:counts].each { |code, count| summary_counts[code] += count } }

      Result.new(ok?: true, payload: {
        from: filters.window.from_date.iso8601,
        upto: filters.window.upto_date.iso8601,
        columns: statuses.map { |status| { id: status.id, code: status.code, name: status.name } },
        rows:,
        summary: { total: summary_counts.values.sum, counts: summary_counts }
      })
    end

    private

    attr_reader :user, :filters

    def columns_for(grouped)
      used = grouped.keys.map(&:last)
      statuses = Catalog.statuses(used)
      codes = filters.status_codes
      return statuses if codes.empty?

      statuses.select { |status| codes.include?(status.code) }
    end

    def rows_for(grouped)
      used = grouped.keys.map(&:first)
      selected = filters.source_ids
      include_none = selected.empty? || filters.source_missing?
      sources = Catalog.sources(used, include_none:)
      return sources if selected.empty? && !filters.source_missing?

      sources.select do |source|
        (source[:id].nil? && filters.source_missing?) || selected.include?(source[:id])
      end
    end

    def tally(grouped, statuses)
      by_id = statuses.index_by(&:id)
      grouped.each_with_object({}) do |((source_id, status_id), count), memo|
        status = by_id[status_id]
        next unless status

        key = Catalog.source_key(source_id)
        memo[key] ||= empty_counts(statuses)
        memo[key][status.code] += count
      end
    end

    def empty_counts(statuses)
      statuses.to_h { |status| [ status.code, 0 ] }
    end
  end
end
