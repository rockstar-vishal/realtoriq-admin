# frozen_string_literal: true

module Reports
  # Rows and columns the grid always shows, plus any inactive master that
  # still has a lead in the result. Hiding the inactive one would drop it
  # from the total.
  class Catalog
    NONE = "none"

    def self.statuses(used_ids)
      records = LeadStatus.active.ordered.to_a
      extra = LeadStatus.where(id: used_ids).where.not(id: records.map(&:id)).ordered
      records + extra.to_a
    end

    def self.sources(used_ids, include_none:)
      records = LeadSource.active.ordered.to_a
      extra_ids = Array(used_ids).compact
      extra = LeadSource.where(id: extra_ids).where.not(id: records.map(&:id)).ordered
      rows = (records + extra.to_a).map { |source| source_row(source) }
      rows << { id: nil, name: "No source" } if include_none
      rows
    end

    def self.source_key(id)
      id.nil? ? NONE : id
    end

    def self.source_row(source)
      { id: source.id, name: source.name }
    end

    def self.rate(part, whole)
      return nil if whole.to_i.zero?

      (part.to_d * 100 / whole.to_d).round(0, :half_up).to_i
    end

    def self.month_row(month)
      {
        month: month.strftime("%Y-%m"),
        label: month.strftime("%b %Y")
      }
    end
  end
end
