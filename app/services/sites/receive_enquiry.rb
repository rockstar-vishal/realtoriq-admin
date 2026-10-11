# frozen_string_literal: true

module Sites
  # A buyer submitted the firm site. The host already picked the firm. A live
  # lead for the same mobile and transaction type is not duplicated. A dead
  # lead does not block a new one. The buyer is not told which happened.
  class ReceiveEnquiry
    SOURCE_NAME = "Broker website"
    NAME_MAX = 80
    MESSAGE_MAX = 500
    Result = Struct.new(:ok?, :error, keyword_init: true)

    def self.call(...)
      new(...).call
    end

    def initialize(firm:, name:, mobile:, message:, listing_kind:, listing_code:)
      @firm = firm
      @name = clip(name, NAME_MAX).tr("\r\n", " ").strip
      @mobile = mobile
      @message = clip(message, MESSAGE_MAX).strip
      @listing_kind = listing_kind.to_s
      @listing_code = listing_code.to_s.upcase
    end

    def call
      return failure("Name is required.") if name.blank?

      phone = indian_mobile(mobile)
      return failure("Enter a 10-digit mobile number.") if phone.nil?

      owner = firm.super_admin
      return failure("Could not send that just now.") if owner.nil? || owner.disabled?

      listing = find_listing
      return failure("Could not send that just now.") if listing.nil?

      Current.set(firm:) do
        deliver(phone, owner, listing)
      end
    end

    private

    attr_reader :firm, :name, :mobile, :message, :listing_kind, :listing_code

    def deliver(phone, owner, listing)
      type = listing.is_a?(Property) && listing.for_rent? ? "rent" : "sale"
      source = LeadSource.find_by(name: SOURCE_NAME)
      return failure("Could not send that just now.") if source.nil?

      property_type = sale_property_type(listing, type)
      return failure("Could not send that just now.") if type == "sale" && property_type.nil?

      attributes = {
        name:,
        mobile: phone,
        transaction_type: type,
        lead_source_id: source.id,
        source_detail: source_detail(listing),
        notes: message.presence,
        assigned_user_id: owner.id,
        budget_max: budget_for(listing)
      }
      attributes[:property_type_id] = property_type.id if property_type

      result = Leads::Create.new(
        firm:,
        actor: owner,
        attributes:,
        typology_ids: typology_ids(listing),
        locality_ids: locality_ids(listing),
        copy_project_typologies: listing.is_a?(Project),
        copy_project_localities: listing.is_a?(Project),
        require_locality: false,
        project_id: listing.is_a?(Project) ? listing.id : nil
      ).call

      lead = result.lead
      if result.error_code == "duplicate_lead"
        lead = Lead.unscoped.find_by(id: result.error_details[:lead_id]) if result.error_details
        return failure("Could not send that just now.") if lead.nil?

        attach(lead, listing, owner)
        note_existing(lead, owner, listing)
        notify(lead, owner, listing, "existing")
        return Result.new(ok?: true)
      end

      return failure("Could not send that just now.") unless result.ok?

      attach_property(lead, listing) if listing.is_a?(Property)
      notify(lead, owner, listing, "created")
      Result.new(ok?: true)
    end

    def find_listing
      return nil unless Host.code?(listing_code)

      case listing_kind
      when "project"
        Project.unscoped.find_by(
          firm_id: firm.id, source: "own", status: "active", on_website: true, code: listing_code
        )
      when "property"
        Property.unscoped.find_by(
          firm_id: firm.id, status: "available", on_website: true, code: listing_code
        )
      end
    end

    def sale_property_type(listing, type)
      return nil unless type == "sale"

      name = if listing.is_a?(Property) || (listing.is_a?(Project) && listing.ready_for_website_sale?)
        "Ready possession"
      else
        "Under construction"
      end
      PropertyType.find_by(name:)
    end

    def budget_for(listing)
      case listing
      when Project then listing.starting_budget
      when Property then listing.price
      end
    end

    def typology_ids(listing)
      return [] unless listing.is_a?(Property)

      [ listing.typology_id ]
    end

    def locality_ids(listing)
      id = listing.is_a?(Property) ? listing.building&.locality_id : nil
      id.present? ? [ id ] : []
    end

    def source_detail(listing)
      label = case listing
      when Project then listing.name
      when Property then listing.title
      else "Home"
      end
      "Broker website · #{clip(label, 80)}"
    end

    def attach(lead, listing, owner)
      return if listing.nil?

      if listing.is_a?(Project)
        return if lead.lead_projects.exists?(project_id: listing.id)

        lead.lead_projects.create!(project: listing, firm:)
        remember_locality(lead, listing.locality_id)
      else
        attach_property(lead, listing)
      end
      lead.lock_for_activity!
    rescue ActiveRecord::RecordInvalid
      nil
    end

    def attach_property(lead, listing)
      return if listing.nil? || !listing.is_a?(Property)
      return if lead.lead_properties.exists?(property_id: listing.id)

      lead.lead_properties.create!(property: listing, firm:)
      remember_locality(lead, listing.building&.locality_id)
    end

    def remember_locality(lead, locality_id)
      return if locality_id.blank?
      return if lead.lead_localities.exists?(locality_id:)

      lead.lead_localities.create!(locality_id:)
    end

    def note_existing(lead, owner, listing)
      comment = [
        "Website enquiry from #{name}.",
        listing && source_detail(listing),
        message.presence
      ].compact.join(" ")
      Leads::RecordFollowup.new(lead:, actor: owner, comment:).call
    end

    def notify(lead, owner, listing, outcome)
      label = case listing
      when Project then listing.name
      when Property then listing.title
      else firm.name
      end
      # Minted once, here, so a retry of the job reuses it and does not open
      # a second inbox row.
      dedupe_key = "website_enquiry:#{lead.id}:#{SecureRandom.uuid}"
      Sites::EnquiryNotifyJob.perform_later(firm.id, lead.id, owner.id, name, label, outcome, dedupe_key)
    end

    def indian_mobile(value)
      phone = Phone.normalise(value)
      phone if phone&.match?(/\A\+91[6-9]\d{9}\z/)
    end

    def clip(value, max)
      value.to_s.delete("\u0000")[0, max]
    end

    def failure(error)
      Result.new(ok?: false, error:)
    end
  end
end
