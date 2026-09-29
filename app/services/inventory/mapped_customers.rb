# frozen_string_literal: true

module Inventory
  # Leads this caller can see that are already mapped to one project or one
  # property. A marketplace row and the firm's booking copy count as the same
  # project, so either screen lists the customers. Withdrawn mappings do not.
  class MappedCustomers
    PER_PAGE = 25
    TURBO_CODE = /\APR[0-9A-F]+\z/i

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
        customers: slice.filter_map { |lead_id, mapped_at| customer_row(leads[lead_id], mapped_at) },
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

    def grouped_rows
      mapping_scope
        .group(:lead_id)
        .order(Arel.sql("MAX(#{table_name}.created_at) DESC"))
        .pluck(:lead_id, Arel.sql("MAX(#{table_name}.created_at)"))
    end

    def mapping_scope
      visible = Lead.visible_to(user).select(:id)
      if site.is_a?(Project)
        LeadProject.where(project_id: project_ids, withdrawn_at: nil).where(lead_id: visible)
      else
        LeadProperty.where(property_id: site.id).where(lead_id: visible)
      end
    end

    def table_name
      site.is_a?(Project) ? "lead_projects" : "lead_properties"
    end

    def project_ids
      if site.marketplace?
        [ site.id, firm_copy_id ].compact
      elsif site.firm_id == user.firm_id && site.external_ref.to_s.match?(TURBO_CODE)
        [ catalog_id, site.id ].compact
      else
        [ site.id ]
      end
    end

    def firm_copy_id
      return if site.external_ref.blank?

      Project.where(source: "own", external_ref: site.external_ref).pick(:id)
    end

    def catalog_id
      return if site.external_ref.blank?

      Project.unscoped.where(
        firm_id: nil, source: "catalog", external_ref: site.external_ref
      ).pick(:id)
    end

    def customer_row(lead, mapped_at)
      return if lead.nil?

      {
        id: lead.id,
        code: lead.code,
        name: lead.display_name,
        mapped_at: mapped_at.iso8601
      }
    end
  end
end
