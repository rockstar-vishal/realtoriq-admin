# frozen_string_literal: true

module Inbound
  # A website posts a buyer's mobile and, usually, a project or property.
  # Budget, locality and configuration are copied from that listing. Sale or
  # rent is never taken from the body when a property is named.
  class ReceiveLead
    PROJECT_CODE = /\AP-[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}\z/i
    PROPERTY_CODE = /\AH-[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}\z/i
    WEB_KEYS = %w[gclid gbraid wbraid utm_source utm_medium utm_campaign utm_term utm_content].freeze
    MESSAGE_LIMIT = 500
    WEB_LIMIT = 200
    ENQUIRY_INDEX = "index_inbound_enquiries_on_firm_channel_and_external_id"
    TEXT_LIMIT = 255

    Result = Struct.new(:ok?, :status, :error, :lead, :listing_name, keyword_init: true)

    def self.call(firm:, channel:, kind:, payload:)
      new(firm:, channel:, kind:, payload: payload.to_h).call
    end

    def initialize(firm:, channel:, kind:, payload:)
      @firm = firm
      @channel = channel
      @kind = kind
      @payload = payload.deep_stringify_keys
    end

    def call
      return failure("This account has no active owner.", notify: false) if actor.nil?

      Current.firm = firm
      Current.user = actor
      return failure("Lead sources are not configured.") if lead_source.nil?

      problem = field_error
      return failure(problem) if problem
      return Result.new(ok?: true, status: "already_in_pipeline") if repeated?

      outcome = kind == "projects" ? project_enquiry : property_enquiry
      notify_success(outcome) if outcome.ok?
      outcome
    end

    private

    attr_reader :firm, :channel, :kind, :payload

    def project_enquiry
      listing = squeeze(payload["listing"])
      return unlisted_sale if listing.blank?

      project = find_project(listing)
      return failure("That project is archived.", listing:) if project == :archived
      return failure("We could not find this project.", listing:) if project.nil?
      if project.project_typologies.empty?
        return failure("This project has no configuration. Add one in RealtorIQ, then try again.", listing:)
      end

      deliver_project(project)
    end

    def property_enquiry
      listing = squeeze(payload["listing"])
      if listing.blank?
        return failure("Send the listing code saved on the property.") if Channels.portal?(channel)

        return unlisted_property
      end

      property = find_property(listing)
      return failure("We could not find this property.", listing:) if property.nil?

      deliver_property(property)
    end

    def unlisted_sale
      fields = UnlistedFields.call(payload, transaction_type: "sale")
      return failure(fields.error) unless fields.ok?

      name = fields.typology.land? ? nil : "Under construction"
      deliver_unlisted(fields, property_type_name: name)
    end

    def unlisted_property
      fields = UnlistedFields.call(payload, transaction_type: nil)
      return failure(fields.error) unless fields.ok?

      name = if fields.typology.land? || fields.transaction_type == "rent"
        nil
      else
        "Ready possession"
      end
      deliver_unlisted(fields, property_type_name: name)
    end

    def deliver_project(project)
      category = project.primary_category
      type = nil
      if category != "land"
        type_name = Inventory::PossessionMatch.ready?(project) ? "Ready possession" : "Under construction"
        type = property_type(type_name)
        return failure("Sale property types are not configured.", listing: project.name) if type.nil?
      end

      phone = indian_mobile
      return failure("Phone must be a 10-digit mobile number.", listing: project.name) if phone.nil?

      saved = nil
      status = nil
      error = nil
      # A savepoint, so a unique-index collision rolls this enquiry back
      # without aborting an outer transaction.
      ActiveRecord::Base.transaction(requires_new: true) do
        saved, status, error = write_project(project, phone, type, category)
        raise ActiveRecord::Rollback if error
        store_enquiry!(saved)
      end
      return failure(error, listing: project.name) if error

      Result.new(ok?: true, status:, lead: saved, listing_name: project.name)
    rescue ActiveRecord::RecordNotUnique => error
      finish_unique(error)
    end

    def write_project(project, phone, type, category)
      lead, status, error = save_project(project, phone, type, category)
      store_web_enquiry!(lead) if error.nil?
      [ lead, status, error ]
    end

    def save_project(project, phone, type, category)
      existing = open_lead(phone, "sale", category)
      if existing
        attach_project(existing, project)
        return [ existing, "already_in_pipeline", note_existing(existing, project.name) ]
      end

      attributes = lead_attributes(phone, "sale", type, project.code, category:)
      attributes[:notes] = enquiry_message if enquiry_message
      result = Leads::Create.new(
        firm:, actor:,
        attributes:,
        project_id: project.id,
        copy_project_typologies: true,
        copy_project_localities: true,
        require_locality: false
      ).call
      return [ result.lead, "created", nil ] if result.ok?
      return duplicate_project(project, phone, category) if result.error_code == "duplicate_lead"

      [ nil, nil, result.error_message.presence || "We could not save this enquiry." ]
    end

    def duplicate_project(project, phone, category)
      existing = open_lead(phone, "sale", category)
      return [ nil, nil, "We could not save this enquiry." ] if existing.nil?

      attach_project(existing, project)
      [ existing, "already_in_pipeline", note_existing(existing, project.name) ]
    end

    def deliver_property(property)
      phone = indian_mobile
      return failure("Phone must be a 10-digit mobile number.", listing: property.code) if phone.nil?

      category = property.typology.category
      type = nil
      if property.for_sale? && category != "land"
        type = property_type("Ready possession")
        return failure("Sale property types are not configured.", listing: property.code) if type.nil?
      end

      saved = nil
      status = nil
      error = nil
      # A savepoint, so a unique-index collision rolls this enquiry back
      # without aborting an outer transaction.
      ActiveRecord::Base.transaction(requires_new: true) do
        saved, status, error = write_property(property, phone, type, category)
        raise ActiveRecord::Rollback if error
        store_enquiry!(saved)
      end
      return failure(error, listing: property.code) if error

      Result.new(ok?: true, status:, lead: saved, listing_name: property.title)
    rescue ActiveRecord::RecordNotUnique => error
      finish_unique(error)
    end

    def write_property(property, phone, type, category)
      existing = open_lead(phone, property.listing_for, category)
      if existing
        attach_property(existing, property)
        return [ existing, "already_in_pipeline", note_existing(existing, property.title) ]
      end

      result = Leads::Create.new(
        firm:, actor:,
        attributes: lead_attributes(phone, property.listing_for, type, property.code, category:)
          .merge(budget: property.price),
        typology_ids: [ property.typology_id ],
        locality_ids: [ property.locality_id ].compact,
        require_locality: property.locality_id.present?
      ).call
      return finish_new_property(result, property) if result.ok?
      return duplicate_property(property, phone, category) if result.error_code == "duplicate_lead"

      [ nil, nil, result.error_message.presence || "We could not save this enquiry." ]
    end

    def finish_new_property(result, property)
      result.lead.lead_properties.create!(property:, firm:)
      [ result.lead, "created", nil ]
    end

    def duplicate_property(property, phone, category)
      existing = open_lead(phone, property.listing_for, category)
      return [ nil, nil, "We could not save this enquiry." ] if existing.nil?

      attach_property(existing, property)
      [ existing, "already_in_pipeline", note_existing(existing, property.title) ]
    end

    def deliver_unlisted(fields, property_type_name:)
      type = property_type_name && property_type(property_type_name)
      if property_type_name && type.nil?
        return failure("Sale property types are not configured.")
      end

      saved = nil
      status = nil
      error = nil
      # A savepoint, so a unique-index collision rolls this enquiry back
      # without aborting an outer transaction.
      ActiveRecord::Base.transaction(requires_new: true) do
        saved, status, error = write_unlisted(fields, type)
        raise ActiveRecord::Rollback if error
        store_enquiry!(saved)
      end
      return failure(error) if error

      Result.new(ok?: true, status:, lead: saved, listing_name: nil)
    rescue ActiveRecord::RecordNotUnique => error
      finish_unique(error)
    end

    def write_unlisted(fields, type)
      category = fields.typology.category
      existing = open_lead(fields.phone, fields.transaction_type, category)
      if existing
        remember(existing, fields.locality.id, fields.typology.id)
        return [ existing, "already_in_pipeline", note_existing(existing, nil) ]
      end

      result = Leads::Create.new(
        firm:, actor:,
        attributes: lead_attributes(fields.phone, fields.transaction_type, type, nil, category:)
          .merge(budget: fields.budget),
        typology_ids: [ fields.typology.id ],
        locality_ids: [ fields.locality.id ]
      ).call
      return [ result.lead, "created", nil ] if result.ok?

      if result.error_code == "duplicate_lead"
        existing = open_lead(fields.phone, fields.transaction_type, category)
        return [ nil, nil, "We could not save this enquiry." ] if existing.nil?

        remember(existing, fields.locality.id, fields.typology.id)
        return [ existing, "already_in_pipeline", note_existing(existing, nil) ]
      end

      [ nil, nil, result.error_message.presence || "We could not save this enquiry." ]
    end

    def lead_attributes(phone, transaction_type, type, code, category:)
      {
        name: payload["name"].to_s.strip.presence&.slice(0, TEXT_LIMIT),
        mobile: phone,
        email: optional_email,
        transaction_type:,
        category:,
        property_type_id: type&.id,
        lead_source_id: lead_source&.id,
        source_detail: source_detail(code)
      }
    end

    def find_project(listing)
      own = find_own_project(listing)
      return own if own

      marketplace_project(listing)
    end

    def find_own_project(listing)
      scope = Project.unscoped.where(firm_id: firm.id, source: "own", status: "active")
      if listing.match?(PROJECT_CODE)
        return scope.find_by("upper(code) = ?", listing.upcase)
      end

      column = Channels.column(channel)
      if column
        match = portal_code_match(scope, channel, listing)
        return match if match
      end

      scope.where("lower(regexp_replace(btrim(name), '\\s+', ' ', 'g')) = ?", listing.downcase).first
    end

    def marketplace_project(listing)
      scope = Project.unscoped.where(firm_id: nil, source: "catalog")
      row = if listing.match?(PROJECT_CODE)
        scope.where("upper(code) = ?", listing.upcase).first
      elsif listing.match?(Leads::Import::LAUNCHIQ_CODE)
        scope.where("upper(external_ref) = ?", listing.upcase).first
      end
      return if row.nil?
      return :archived if row.archived?

      row
    end

    def find_property(listing)
      scope = Property.unscoped.where(firm_id: firm.id)
      if listing.match?(PROPERTY_CODE)
        return scope.includes(:locality).find_by("upper(code) = ?", listing.upcase)
      end

      column = Channels.column(channel)
      return if column.nil?

      portal_code_match(scope.includes(:locality), channel, listing)
    end

    def portal_code_match(scope, channel, listing)
      value = listing.downcase
      case channel
      when "99acres" then scope.where("lower(portal_99acres_code) = ?", value).first
      when "magicbricks" then scope.where("lower(portal_magicbricks_code) = ?", value).first
      when "housing" then scope.where("lower(portal_housing_code) = ?", value).first
      end
    end

    def attach_project(lead, project)
      lead.lead_projects.create!(project:, firm:) unless lead.lead_projects.exists?(project_id: project.id)
      remember(lead, project.locality_id, nil)
      project.typology_ids_for(lead.category).each { |id| remember_typology(lead, id) }
    end

    def attach_property(lead, property)
      unless lead.lead_properties.exists?(property_id: property.id)
        lead.lead_properties.create!(property:, firm:)
      end
      remember(lead, property.locality_id, property.typology_id)
    end

    def remember(lead, locality_id, typology_id)
      remember_locality(lead, locality_id)
      remember_typology(lead, typology_id)
    end

    def remember_locality(lead, locality_id)
      return if locality_id.blank? || lead.lead_localities.exists?(locality_id:)

      lead.lead_localities.create!(locality_id:)
    end

    def remember_typology(lead, typology_id)
      return if typology_id.blank? || lead.lead_typologies.exists?(typology_id:)

      lead.lead_typologies.create!(typology_id:)
    end

    def note_existing(lead, listing_name)
      comment = [ "New #{Channels.label(channel)} enquiry", listing_name.presence && "for #{listing_name}" ].compact.join(" ")
      comment = "#{comment}."
      comment = "#{comment} #{enquiry_message}" if kind == "projects" && enquiry_message
      result = Leads::RecordFollowup.new(lead:, actor:, comment:).call
      return if result.ok?

      result.error_message.presence || "We could not save this enquiry."
    end

    def enquiry_message
      payload["message"].to_s.strip.presence
    end

    def store_web_enquiry!(lead)
      return if lead.nil?

      incoming = {}
      WEB_KEYS.each do |key|
        value = payload[key].to_s.strip
        next if value.blank?

        incoming[key] = value
      end
      incoming["consent_at"] = Time.current.iso8601 if payload["consent"].to_s.strip == "yes"
      return if incoming.empty?

      lead.update!(web_enquiry: lead.web_enquiry.to_h.merge(incoming))
    end

    def store_enquiry!(lead)
      return if enquiry_id.blank? || lead.nil?

      lead.lock_for_activity!
      InboundEnquiry.create!(firm:, channel:, external_id: enquiry_id, lead:)
    end

    def repeated?
      return false if enquiry_id.blank?

      InboundEnquiry.across_firms.exists?(firm_id: firm.id, channel:, external_id: enquiry_id)
    end

    def open_lead(phone, transaction_type, category)
      Lead.unscoped.find_by(firm_id: firm.id, transaction_type:, category:, open_identity: phone)
    end

    def indian_mobile
      raw = payload["mobile"].to_s
      return if raw.length > 32

      phone = Phone.normalise(raw)
      phone if phone&.match?(/\A\+91\d{10}\z/)
    end

    def property_type(name) = PropertyType.find_by(name:)

    def lead_source
      return @lead_source if defined?(@lead_source)

      @lead_source = LeadSource.find_by(name: Channels.source_name(channel))
    end

    def enquiry_id = payload["enquiry_id"].to_s.strip.presence

    # User's default scope matches nothing until a tenant is set, and this
    # runs before Current.firm is. Load the owner explicitly.
    def actor
      return @actor if defined?(@actor)

      owner = User.across_firms.find_by(firm_id: firm.id, role: "super_admin")
      @actor = owner&.active? ? owner : nil
    end

    def field_error
      return "That message is too long." if payload["message"].to_s.length > MESSAGE_LIMIT

      WEB_KEYS.each do |key|
        return "That #{key} is too long." if payload[key].to_s.length > WEB_LIMIT
      end
      return "That listing code is too long." if payload["listing"].to_s.length > TEXT_LIMIT
      return "That enquiry id is too long." if payload["enquiry_id"].to_s.strip.length > TEXT_LIMIT
      return "That city name is too long." if payload["city"].to_s.length > TEXT_LIMIT
      return "That locality name is too long." if payload["locality"].to_s.length > TEXT_LIMIT
      return "That configuration name is too long." if payload["configuration"].to_s.length > TEXT_LIMIT

      nil
    end

    def optional_email
      text = payload["email"].to_s.strip.presence
      return if text.nil?

      text = text.slice(0, TEXT_LIMIT)
      text if text.match?(URI::MailTo::EMAIL_REGEXP)
    end

    def source_detail(code)
      [ code, enquiry_id && "enquiry #{enquiry_id}" ].compact.join(" · ").presence&.slice(0, TEXT_LIMIT)
    end

    # Only the enquiry-id collision is "already saved". Any other unique
    # index means this request's lead was rolled back.
    def finish_unique(error)
      text = [ error.message, error.cause&.message ].compact.join(" ")
      return Result.new(ok?: true, status: "already_in_pipeline") if text.include?(ENQUIRY_INDEX)

      failure("We could not save this enquiry.")
    end

    def squeeze(value) = value.to_s.strip.gsub(/\s+/, " ")

    def failure(message, listing: nil, notify: true)
      Notify.failure(user: actor, channel:, mobile: payload["mobile"], listing:, message:) if notify
      Result.new(ok?: false, error: message)
    end

    def notify_success(outcome)
      Notify.success(
        user: actor, channel:, lead: outcome.lead, enquiry_id:,
        listing_name: outcome.listing_name, created: outcome.status == "created"
      )
    end
  end
end
