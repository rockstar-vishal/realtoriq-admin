# frozen_string_literal: true

module Inventory
  # Who has visited one project or one property. Counts and rows are limited
  # to leads the caller can see, so an agent does not learn another agent's
  # clients from a firm-wide inventory page.
  class VisitorList
    PER_PAGE = 25

    def initialize(site:, user:, page:)
      @site = site
      @user = user
      @page = [ page.to_i, 1 ].max
    end

    def as_json
      grouped = grouped_rows
      slice = grouped.drop((page - 1) * PER_PAGE).first(PER_PAGE)
      leads = Lead.where(id: slice.map(&:first)).index_by(&:id)

      {
        visit_count: outing_count,
        visitors: slice.filter_map { |lead_id, count, last_at| visitor_row(leads[lead_id], count, last_at) },
        meta: {
          page:,
          per_page: PER_PAGE,
          total_count: grouped.size,
          total_pages: (grouped.size.to_f / PER_PAGE).ceil
        }
      }
    end

    private

    attr_reader :site, :user, :page

    def outing_count
      visit_scope.count
    end

    def grouped_rows
      visit_scope
        .group(:lead_id)
        .order(Arel.sql("MAX(lead_visits.visited_at) DESC"))
        .pluck(:lead_id, Arel.sql("COUNT(*)"), Arel.sql("MAX(lead_visits.visited_at)"))
    end

    def visit_scope
      if site.is_a?(Project)
        LeadVisit.joins(:lead_visit_projects)
          .where(lead_visit_projects: { project_id: site.id })
      else
        LeadVisit.joins(:lead_visit_properties)
          .where(lead_visit_properties: { property_id: site.id })
      end.where(lead_id: Lead.visible_to(user).select(:id))
    end

    def visitor_row(lead, count, last_at)
      return if lead.nil?

      {
        lead: {
          id: lead.id,
          code: lead.code,
          display_name: lead.display_name,
          mobile: lead.mobile
        },
        visit_count: count.to_i,
        last_visited_on: last_at.in_time_zone(Lead::NCD_ZONE).to_date.iso8601
      }
    end
  end
end
