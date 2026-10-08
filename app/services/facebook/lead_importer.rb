# frozen_string_literal: true

module Facebook
  # Turns a fetched lead into a CRM lead. Budget, configuration and locality
  # come from the listing. A duplicate is recorded and left as it is.
  class LeadImporter
    TEXT_LIMIT = 255
    Result = Struct.new(:status, :lead, :error, keyword_init: true)

    def self.call(import:, form:, payload:)
      new(import:, form:, payload:).call
    end

    def initialize(import:, form:, payload:)
      @import = import
      @form = form
      @payload = payload.to_h.deep_stringify_keys
      @firm = import.firm
    end

    def call
      return invalid("This firm is not active.") unless firm.active?
      return invalid("This firm has no active super admin.") if actor.nil?

      problem = listing_problem
      return invalid(problem) if problem

      fields = mapped_fields
      if fields.mobile.blank? || fields.mobile_invalid
        return invalid("Mobile is missing or isn't a valid phone number")
      end

      source = resolve_source
      return source if source.is_a?(Result)
      return invalid("Lead sources are not configured") if source.nil?

      details = {}
      assignee_id = assignee_id_for(details)
      outcome = nil
      ActiveRecord::Base.transaction(requires_new: true) do
        outcome = form.project_id.present? ? write_project(fields, source, assignee_id) : write_property(fields, source, assignee_id)
        outcome.lead.lock_for_activity! if outcome.lead && outcome.status.in?(%i[created duplicate])
        case outcome.status
        when :created
          import.mark_created!(lead: outcome.lead, error_details: details.presence)
        when :duplicate
          import.mark_duplicate!(lead: outcome.lead)
        else
          raise ActiveRecord::Rollback
        end
      end
      outcome
    end

    private

    attr_reader :import, :form, :payload, :firm

    def invalid(error)
      Result.new(status: :invalid, error:)
    end

    def listing_problem
      message = form.ready_for_import_error
      return message if message
      return if form.project_id.blank?

      project = form.project
      return if project.nil? || project.project_typologies.any?

      "#{project.name} has no configuration"
    end

    def mapped_fields
      FieldMapper.apply(
        field_data: FieldMapper.extract_field_data(payload),
        mappings: form.field_mappings,
        questions: form.questions
      )
    end

    def resolve_source
      if form.lead_source_id.present?
        source = form.lead_source
        return source if source&.active?

        return invalid("The chosen lead source is turned off")
      end

      LeadSource.find_by(name: "Social / Meta")
    end

    def assignee_id_for(details)
      user = form.assigned_user
      return if user.nil?
      return user.id if user.firm_id == firm.id && user.active?

      details["assignee_dropped"] = true
      nil
    end

    def write_project(fields, source, assignee_id)
      project = form.project
      type_name = Inventory::PossessionMatch.ready?(project) ? "Ready possession" : "Under construction"
      type = PropertyType.find_by(name: type_name)
      return invalid("Sale property types are not configured.") if type.nil?

      existing = open_lead(fields.mobile, "sale")
      return Result.new(status: :duplicate, lead: existing) if existing

      result = Leads::Create.new(
        firm:, actor:,
        attributes: lead_attributes(fields, "sale", type, source, assignee_id),
        project_id: project.id,
        copy_project_typologies: true,
        copy_project_localities: true,
        require_locality: false
      ).call
      return Result.new(status: :created, lead: result.lead) if result.ok?
      return duplicate_result(fields.mobile, "sale") if result.error_code == "duplicate_lead"

      invalid(result.error_message.presence || "We could not save this lead.")
    end

    def write_property(fields, source, assignee_id)
      property = form.property
      type = property.for_sale? ? PropertyType.find_by(name: "Ready possession") : nil
      return invalid("Sale property types are not configured.") if property.for_sale? && type.nil?

      existing = open_lead(fields.mobile, property.listing_for)
      return Result.new(status: :duplicate, lead: existing) if existing

      result = Leads::Create.new(
        firm:, actor:,
        attributes: lead_attributes(fields, property.listing_for, type, source, assignee_id).merge(budget: property.price),
        typology_ids: [ property.typology_id ],
        locality_ids: [ property.building&.locality_id ].compact,
        require_locality: property.building&.locality_id.present?
      ).call
      return finish_property(result, property) if result.ok?
      return duplicate_result(fields.mobile, property.listing_for) if result.error_code == "duplicate_lead"

      invalid(result.error_message.presence || "We could not save this lead.")
    end

    def finish_property(result, property)
      result.lead.lead_properties.create!(property:, firm:)
      Result.new(status: :created, lead: result.lead)
    end

    def duplicate_result(phone, transaction_type)
      existing = open_lead(phone, transaction_type)
      return invalid("We could not save this lead.") if existing.nil?

      Result.new(status: :duplicate, lead: existing)
    end

    def lead_attributes(fields, transaction_type, type, source, assignee_id)
      {
        name: fields.name.to_s.strip.presence&.slice(0, TEXT_LIMIT),
        mobile: fields.mobile,
        email: fields.email,
        alt_mobile: fields.alt_mobile,
        notes: fields.notes,
        lead_source_id: source.id,
        source_detail: source_detail,
        transaction_type:,
        property_type_id: type&.id,
        assigned_user_id: assignee_id
      }.compact
    end

    def source_detail
      parts = [ "Facebook", form.form_name ]
      parts << payload["ad_name"] if payload["ad_name"].present?
      parts.join(" · ").slice(0, TEXT_LIMIT)
    end

    def open_lead(phone, transaction_type)
      Lead.unscoped.find_by(firm_id: firm.id, transaction_type:, open_identity: phone)
    end

    # Matches Inbound::ReceiveLead#actor. A disabled row is not skipped in
    # favour of another super admin.
    def actor
      return @actor if defined?(@actor)

      owner = User.across_firms.find_by(firm_id: firm.id, role: "super_admin")
      @actor = owner&.active? ? owner : nil
    end
  end
end
