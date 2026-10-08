# frozen_string_literal: true

module Realtoriq
  # A buyer submitted the public microsite form. The share token picks the firm
  # and the broker. A live lead is not duplicated. A dead lead does not block
  # a new one. The same enquiry_id again does nothing.
  class ReceiveEnquiry
    Result = Struct.new(:ok?, :status, :error, keyword_init: true)

    ENQUIRY_INDEX = "index_marketplace_enquiries_on_enquiry_id"
    SOURCE_NAME = "Builder Microsite"
    FRESH_FOR = 10.minutes

    def self.call(payload)
      new(payload).call
    end

    def initialize(payload)
      @payload = payload.to_h.deep_stringify_keys
    end

    def call
      return failure("enquiry_id is required") if payload["enquiry_id"].blank?
      return failure("This enquiry has expired.") unless fresh?

      link = ProjectShareLink.across_firms.find_by(token: payload["share_token"].to_s)
      return failure("This link is not valid.") if link.nil?
      return failure("This link is no longer active.") unless link.firm&.active?

      project = Project.unscoped.find_by(
        source: "catalog", firm_id: nil, external_ref: payload["project_code"].to_s, status: "active"
      )
      return failure("This project is not available.") if project.nil? || project.id != link.project_id

      phone = Phone.normalise(payload["phone"])
      return failure("Phone must be a 10-digit mobile number.") unless phone&.match?(/\A\+91\d{10}\z/)

      property_type = PropertyType.find_by(name: "Under construction")
      return failure("Sale property types are not configured.") if property_type.nil?

      lead_source = LeadSource.find_by(name: SOURCE_NAME)
      return failure("Lead sources are not configured.") if lead_source.nil?

      owner = recipient(link)
      return failure("This link is no longer active.") if owner.nil?
      return Result.new(ok?: true, status: :ok) if already_received?

      Current.firm = link.firm
      deliver(link, project, phone, property_type, lead_source, owner)
    rescue ActiveRecord::RecordNotUnique => e
      raise unless e.message.include?(ENQUIRY_INDEX)

      Result.new(ok?: true, status: :ok)
    rescue ActiveRecord::RecordInvalid => e
      raise unless enquiry_already_stored?(e)

      Result.new(ok?: true, status: :ok)
    end

    private

    attr_reader :payload

    def deliver(link, project, phone, property_type, lead_source, owner)
      failure_result = nil
      ActiveRecord::Base.transaction do
        MarketplaceEnquiry.create!(
          firm: link.firm,
          project_share_link: link,
          enquiry_id: payload["enquiry_id"],
          submitted_at:
        )

        existing = Lead.unscoped.find_by(firm_id: link.firm_id, transaction_type: "sale", open_identity: phone)
        if existing
          lead = existing
          outcome = "existing"
          attach_project(existing, project, link.firm)
          remember_locality(existing, project)
          note_existing(existing, owner)
        else
          created = create_lead(link, project, phone, property_type, lead_source, owner)
          if created.is_a?(Result)
            failure_result = created
            raise ActiveRecord::Rollback
          end
          outcome, lead = created
        end
        lead.lock_for_activity!
        MarketplaceEnquiry.find_by!(enquiry_id: payload["enquiry_id"]).update!(lead:, outcome:)
        EnquiryNotifyJob.perform_later(
          link.firm_id, lead.id, notify_user(lead, owner).id, payload["enquiry_id"],
          payload["name"].to_s.strip.presence, project.name, outcome
        )
      end
      failure_result || Result.new(ok?: true, status: :ok)
    end

    def already_received?
      MarketplaceEnquiry.across_firms.exists?(enquiry_id: payload["enquiry_id"])
    end

    # Uniqueness is checked before the insert, so a repeat raises RecordInvalid
    # and never reaches the unique index. That is still a no-op for the buyer.
    def enquiry_already_stored?(error)
      error.record.is_a?(MarketplaceEnquiry) && error.record.errors.where(:enquiry_id, :taken).any?
    end

    def fresh?
      return false if pushed_at.nil?

      (Time.current - pushed_at).abs <= FRESH_FOR
    end

    def pushed_at
      return @pushed_at if defined?(@pushed_at)

      raw = payload["pushed_at"].presence
      @pushed_at = raw && Time.iso8601(raw)
    rescue ArgumentError
      @pushed_at = nil
    end

    def submitted_at
      raw = payload["submitted_at"].presence
      raw && Time.iso8601(raw)
    rescue ArgumentError
      nil
    end

    def recipient(link)
      user = link.user&.active? ? link.user : link.firm.super_admin
      user if user&.active?
    end

    def notify_user(lead, owner)
      lead.assigned_user&.active? ? lead.assigned_user : owner
    end

    def create_lead(link, project, phone, property_type, lead_source, owner)
      result = Leads::Create.new(
        firm: link.firm,
        actor: owner,
        attributes: {
          name: payload["name"].to_s.strip.presence,
          mobile: phone,
          transaction_type: "sale",
          property_type_id: property_type.id,
          lead_source_id: lead_source.id,
          source_detail: "Marketplace #{payload['project_code']}",
          notes: payload["message"].presence,
          assigned_user_id: owner.id
        },
        project_id: project.id,
        copy_project_typologies: true,
        copy_project_localities: true,
        require_locality: false
      ).call

      return [ "created", result.lead ] if result.ok?

      if result.error_code == "duplicate_lead"
        existing = result.error_details && Lead.unscoped.find_by(id: result.error_details[:lead_id])
        attach_project(existing, project, link.firm) if existing
        remember_locality(existing, project)
        note_existing(existing, owner)
        return [ "existing", existing ]
      end

      failure(result.error_message.presence || result.lead&.errors&.full_messages&.to_sentence || "Could not save the enquiry.")
    end

    def attach_project(lead, project, firm)
      return if lead.lead_projects.exists?(project_id: project.id)

      lead.lead_projects.create!(project:, firm:)
    end

    def remember_locality(lead, project)
      return if lead.nil? || project.locality_id.blank?
      return if lead.lead_localities.exists?(locality_id: project.locality_id)

      lead.lead_localities.create!(locality_id: project.locality_id)
    end

    def note_existing(lead, owner)
      return if lead.nil?

      recipient = lead.assigned_user&.active? ? lead.assigned_user : owner
      return if recipient.nil?

      comment = [
        "Marketplace enquiry from #{payload['name'].presence || 'a client'}.",
        payload["message"].presence
      ].compact.join(" ")
      Leads::RecordFollowup.new(lead:, actor: recipient, comment:).call
      return if recipient.email.blank?

      EnquiryMailJob.perform_later(
        lead.firm_id, lead.id, recipient.id, payload["name"].to_s.strip.presence
      )
    end

    def failure(error)
      Result.new(ok?: false, status: :unprocessable_entity, error:)
    end
  end
end
