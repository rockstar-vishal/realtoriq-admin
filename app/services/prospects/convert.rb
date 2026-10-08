# frozen_string_literal: true

module Prospects
  # Turns an interested call into a lead. Runs inside the caller's transaction
  # so a failed lead does not leave a follow-up or a status change behind.
  # No opening lead follow-up: "has the lead been worked?" stays false until
  # the broker logs one on the lead itself.
  class Convert
    Result = Struct.new(:ok?, :prospect, :followup, :error_code, :error_message, :error_details,
      keyword_init: true)

    def initialize(prospect:, actor:, notes:, lead:)
      @prospect = prospect
      @actor = actor
      @notes = notes.to_s.strip
      @lead = lead_input(lead)
    end

    def call
      attributes = build_attributes
      return attributes if attributes.is_a?(Result)

      created = ::Leads::Create.new(
        firm: prospect.firm, actor:, attributes: attributes[:lead],
        typology_ids: attributes[:typology_ids],
        copy_project_typologies: attributes[:copy_project],
        locality_ids: attributes[:locality_ids],
        copy_project_localities: attributes[:copy_project],
        project_id: attributes[:project]&.id
      ).call
      return lead_failure(created) unless created.ok?

      link_property(created.lead, attributes[:property]) if attributes[:property]
      followup = write_followup
      prospect.update!(status: "interested", lead: created.lead, next_action_at: nil)
      Result.new(ok?: true, prospect:, followup:)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok?: false, prospect:, error_code: "invalid",
        error_message: e.record.errors.full_messages.to_sentence,
        error_details: e.record.errors.to_hash)
    end

    private

    attr_reader :prospect, :actor, :notes, :lead

    def lead_input(raw)
      return {}.with_indifferent_access if raw.blank?

      hash = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h
      hash.with_indifferent_access
    end

    def build_attributes
      case lead[:mode].to_s
      when "project" then from_project
      when "property" then from_property
      when "requirements" then from_requirements
      else
        failure("Choose a project, a property, or the client's requirements.")
      end
    end

    def from_project
      project = Inventory.project_by_id(lead[:project_id])
      return failure(project_message(project)) unless project.is_a?(Project)

      {
        lead: base_lead("sale", lead[:property_type_id], budget: blankable(lead[:budget])),
        typology_ids: array_ids(:typology_ids),
        locality_ids: array_ids(:locality_ids),
        copy_project: true,
        project:,
        property: nil
      }
    end

    def from_property
      property = Inventory.property_by_id(lead[:property_id])
      return failure(property_message(property)) unless property.is_a?(Property)

      locality_id = property.building&.locality_id
      type_id = property.for_sale? ? lead[:property_type_id] : nil
      {
        lead: base_lead(property.listing_for, type_id, budget: property.price),
        typology_ids: [ property.typology_id ].compact,
        locality_ids: [ locality_id ].compact,
        copy_project: false,
        project: nil,
        property:
      }
    end

    def from_requirements
      type = lead[:transaction_type].to_s
      return failure("Choose sale or rent.") unless Lead::TRANSACTION_TYPES.include?(type)

      budget = whole_rupees(lead[:budget])
      return failure("Budget must be a whole number of rupees.") if lead[:budget].present? && budget.nil?

      type_id = type == "sale" ? lead[:property_type_id] : nil
      {
        lead: base_lead(type, type_id, budget:),
        typology_ids: array_ids(:typology_ids),
        locality_ids: array_ids(:locality_ids),
        copy_project: false,
        project: nil,
        property: nil
      }
    end

    def base_lead(transaction_type, property_type_id, budget:)
      payload = {
        name: prospect.name,
        mobile: prospect.mobile,
        transaction_type:,
        notes: combined_notes,
        lead_source_id: telecalling_source.id
      }
      payload[:property_type_id] = property_type_id if property_type_id.present?
      payload[:budget] = budget if budget.present?
      payload
    end

    def telecalling_source
      LeadSource.find_or_create_by!(name: "Telecalling") do |source|
        source.category = "outbound"
        source.sort_order = (LeadSource.maximum(:sort_order) || -1) + 1
      end
    end

    def combined_notes
      [ prospect.comment, notes ].compact_blank.join("\n\n").presence
    end

    def link_property(record, property)
      record.lead_properties.create!(property:, firm: prospect.firm)
    end

    def write_followup
      prospect.prospect_followups.create!(
        firm: prospect.firm, user: actor, connected: true, notes:,
        outcome: "interested", next_action_at: nil
      )
    end

    def array_ids(key)
      Array(lead[key]).compact_blank
    end

    def blankable(value)
      whole_rupees(value)
    end

    def whole_rupees(value)
      return if value.blank?

      text = value.to_s.strip
      return unless text.match?(/\A\d+\z/)

      amount = text.to_i
      amount if amount.positive?
    end

    def project_message(value)
      value.is_a?(String) ? value : "Choose a project."
    end

    def property_message(value)
      value.is_a?(String) ? value : "Choose a property."
    end

    def lead_failure(result)
      if result.error_code == "duplicate_lead"
        return Result.new(ok?: false, prospect:, error_code: "duplicate_lead",
          error_message: result.error_message, error_details: duplicate_details(result))
      end

      message = result.error_message.presence || result.errors&.full_messages&.to_sentence ||
        "The lead could not be created."
      Result.new(ok?: false, prospect:, error_code: result.error_code || "invalid",
        error_message: message, error_details: result.errors&.to_hash)
    end

    def duplicate_details(result)
      details = (result.error_details || {}).symbolize_keys
      existing = details[:lead_id] && Lead.find_by(id: details[:lead_id])
      return details unless existing

      accessible = actor.super_admin? || actor.manager? || existing.assigned_user_id == actor.id
      details[:lead_code] = existing.code
      details[:lead_accessible] = accessible
      details.delete(:lead_id) unless accessible
      details
    end

    def failure(message)
      Result.new(ok?: false, prospect:, error_code: "invalid", error_message: message)
    end
  end
end
