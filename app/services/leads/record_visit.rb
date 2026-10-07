# frozen_string_literal: true

module Leads
  # The only write path for a completed outing. Does not move pipeline status,
  # NCD, or follow-up comments. Mapping is required for new site ids. Ids
  # already on this visit may stay after the lead unmaps them.
  class RecordVisit
    Result = Struct.new(:ok?, :visit, :error_code, :error_message, :details, keyword_init: true)

    def initialize(lead:, actor:, attributes:, visit: nil)
      @lead = lead
      @actor = actor
      @attributes = attributes
      @visit = visit
    end

    def call
      visit ? update_visit : create_visit
    end

    private

    attr_reader :lead, :actor, :attributes, :visit

    def create_visit
      return failure("visited_on_required", "A visit needs the date it happened.") unless attributes.key?(:visited_on)

      visited_at = parse_visited_on(attributes[:visited_on])
      return invalid_date if attributes[:visited_on].present? && visited_at.nil?
      return future_date if visited_at && future?(visited_at)

      project_ids = normalize_ids(attributes[:project_ids])
      property_ids = normalize_ids(attributes[:property_ids])
      missing = unmapped(project_ids, property_ids)
      return not_mapped(missing) if missing

      created = nil
      Lead.transaction do
        created = lead.lead_visits.create!(
          firm: lead.firm, user: actor, visited_at:, notes: blank_to_nil(attributes[:notes])
        )
        replace_sites(created, project_ids, property_ids)
      end

      Result.new(ok?: true, visit: decorated(created))
    rescue ActiveRecord::RecordInvalid => e
      failure("invalid", e.record.errors.full_messages.to_sentence, e.record.errors.to_hash)
    end

    def update_visit
      visited_at = visit.visited_at
      if attributes.key?(:visited_on)
        visited_at = parse_visited_on(attributes[:visited_on])
        return invalid_date if visited_at.nil?
        return future_date if future?(visited_at)
      end

      project_ids = attributes.key?(:project_ids) ? normalize_ids(attributes[:project_ids]) : nil
      property_ids = attributes.key?(:property_ids) ? normalize_ids(attributes[:property_ids]) : nil
      already_projects = visit.lead_visit_projects.pluck(:project_id).map(&:to_s)
      already_properties = visit.lead_visit_properties.pluck(:property_id).map(&:to_s)
      missing = unmapped(
        project_ids.nil? ? [] : project_ids - already_projects,
        property_ids.nil? ? [] : property_ids - already_properties
      )
      return not_mapped(missing) if missing

      Lead.transaction do
        visit.visited_at = visited_at
        visit.notes = blank_to_nil(attributes[:notes]) if attributes.key?(:notes)
        visit.save!
        replace_projects(visit, project_ids) unless project_ids.nil?
        replace_properties(visit, property_ids) unless property_ids.nil?
      end

      Result.new(ok?: true, visit: decorated(visit))
    rescue ActiveRecord::RecordInvalid => e
      failure("invalid", e.record.errors.full_messages.to_sentence, e.record.errors.to_hash)
    end

    def replace_sites(record, project_ids, property_ids)
      replace_projects(record, project_ids)
      replace_properties(record, property_ids)
    end

    def replace_projects(record, ids)
      record.lead_visit_projects.where.not(project_id: ids).destroy_all
      existing = record.lead_visit_projects.pluck(:project_id).map(&:to_s)
      (ids - existing).each do |project_id|
        record.lead_visit_projects.create!(firm: record.firm, project_id:)
      end
    end

    def replace_properties(record, ids)
      record.lead_visit_properties.where.not(property_id: ids).destroy_all
      existing = record.lead_visit_properties.pluck(:property_id).map(&:to_s)
      (ids - existing).each do |property_id|
        record.lead_visit_properties.create!(firm: record.firm, property_id:)
      end
    end

    def decorated(record)
      LeadVisit.includes(:user, :projects, :properties).find(record.id)
    end

    def unmapped(project_ids, property_ids)
      mapped_projects = lead.lead_projects.where(project_id: project_ids).pluck(:project_id).map(&:to_s)
      mapped_properties = lead.lead_properties.where(property_id: property_ids).pluck(:property_id).map(&:to_s)
      missing_projects = project_ids - mapped_projects
      missing_properties = property_ids - mapped_properties
      return if missing_projects.empty? && missing_properties.empty?

      { project_ids: missing_projects, property_ids: missing_properties }
    end

    def normalize_ids(value)
      Array(value).filter_map { |id| id.to_s.presence }.uniq
    end

    def parse_visited_on(raw)
      text = raw.to_s.strip
      return if text.blank?

      zone = Time.find_zone(Lead::NCD_ZONE)
      parsed = zone.parse(text)
      return if parsed.nil?

      parsed.beginning_of_day
    end

    def future?(time)
      time.to_date > Time.find_zone(Lead::NCD_ZONE).today
    end

    def blank_to_nil(value)
      text = value.to_s.strip
      text.presence
    end

    def invalid_date
      failure("invalid", "visited_on must be a date (YYYY-MM-DD).")
    end

    def future_date
      failure("future_visited_at", "A visit date cannot be after today.")
    end

    def not_mapped(missing)
      failure("not_mapped", "Sites added to a visit must already be mapped to this lead.", missing)
    end

    def failure(code, message, details = nil)
      Result.new(ok?: false, error_code: code, error_message: message, details:)
    end
  end
end
