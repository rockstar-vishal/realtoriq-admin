# frozen_string_literal: true

module Realtoriq
  # Leads mapped to a marketplace project, and whether a visit pass for it
  # has been generated or scanned. A booking copy is included so a lead mapped
  # before this rule still shows.
  class ProjectLeads
    TURBO_CODE = /\APR[0-9A-F]+\z/i
    PAGE_SIZE = 25
    Result = Struct.new(:leads, :page, :per_page, :total_count, :total_pages, keyword_init: true)

    def initialize(project:, user:)
      @project = project
      @user = user
    end

    def call(page: 1)
      page = page.to_i
      page = 1 if page < 1
      ids = related_project_ids
      return empty(page) if ids.empty?

      scope = LeadProject.where(project_id: ids).order(created_at: :desc, id: :desc)
      total = scope.count
      mappings = scope.offset((page - 1) * PAGE_SIZE).limit(PAGE_SIZE).to_a
      mappings = mappings.uniq(&:lead_id)
      leads = Lead.visible_to(user).where(id: mappings.map(&:lead_id)).index_by(&:id)
      passes = latest_passes(ids, leads.keys)

      Result.new(
        leads: mappings.filter_map { |mapping|
          lead = leads[mapping.lead_id]
          next if lead.nil?

          serialize(lead, mapping, passes[lead.id])
        },
        page:,
        per_page: PAGE_SIZE,
        total_count: total,
        total_pages: (total.to_f / PAGE_SIZE).ceil
      )
    end

    private

    attr_reader :project, :user

    def empty(page)
      Result.new(leads: [], page:, per_page: PAGE_SIZE, total_count: 0, total_pages: 0)
    end

    def related_project_ids
      if project.marketplace?
        [ project.id, firm_copy_id ].compact
      elsif project.firm_id == user.firm_id && project.external_ref.to_s.match?(TURBO_CODE)
        [ catalog_id, project.id ].compact
      else
        []
      end
    end

    def firm_copy_id
      return if project.external_ref.blank?

      Project.where(source: "own", external_ref: project.external_ref).pick(:id)
    end

    def catalog_id
      return if project.external_ref.blank?

      Project.unscoped.where(
        firm_id: nil, source: "catalog", external_ref: project.external_ref
      ).pick(:id)
    end

    def latest_passes(project_ids, lead_ids)
      found = {}
      LeadVisitPass.where(project_id: project_ids, lead_id: lead_ids).order(created_at: :desc).each do |pass|
        found[pass.lead_id] ||= pass
      end
      found
    end

    def serialize(lead, mapping, pass)
      {
        id: lead.id,
        code: lead.code,
        name: lead.display_name,
        withdrawn: mapping.withdrawn_at.present?,
        pass_generated: pass.present?,
        shared_with_builder: pass&.turbo_status == "used",
        status: status_label(pass),
        pass_code: pass&.pass_code,
        turbo_status: pass&.turbo_status
      }
    end

    def status_label(pass)
      return "No pass" if pass.nil?

      case pass.turbo_status
      when "used" then "Shared with builder"
      when "duplicate" then "Already registered with the builder"
      when "pending" then "Pass pending"
      else "Pass generated"
      end
    end
  end
end
