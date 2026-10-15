# frozen_string_literal: true

module Onboarding
  # Ops corrections. Contacts, verification times, the acceptance and the
  # firm's slug and code stay as they were submitted.
  class UpdateDetails
    FIELDS = %w[
      applicant_name applicant_designation entity_type firm_name legal_name
      address_line1 address_line2 city_id locality_id pincode extra_locality_ids
      pan gst_number team_size rera_registered rera_number rera_valid_till internal_notes
    ].freeze

    def initialize(application, params)
      @application = application
      @params = params
    end

    def save
      return false unless application.submitted? && !application.firm.discarded?

      application.assign_attributes(attributes)
      unless extras_belong_to_city?
        application.errors.add(:extra_locality_ids, "must be other active localities in this city")
        return false
      end
      return false unless application.valid?

      names = changed_names
      Firm.transaction do
        application.save!
        sync_firm
        AuditEvent.record!(
          subject: application, action: "onboarding.edited", firm: application.firm,
          metadata: { fields: names }
        )
      end
      true
    end

    private

    attr_reader :application, :params

    def attributes
      raw = params.slice(*FIELDS)
      if raw.key?(:extra_locality_ids) || raw.key?("extra_locality_ids")
        raw[:extra_locality_ids] = Array(raw[:extra_locality_ids]).reject(&:blank?)
      end
      if raw[:entity_type].to_s == "individual" && raw[:legal_name].blank?
        raw[:legal_name] = raw[:applicant_name].presence || application.applicant_name
      end
      return raw unless raw.key?(:rera_registered) || raw.key?("rera_registered")

      if ActiveModel::Type::Boolean.new.cast(raw[:rera_registered])
        raw[:rera_declared_at] = nil
      else
        raw[:rera_number] = nil
        raw[:rera_valid_till] = nil
        raw[:rera_declared_at] = application.rera_declared_at || Time.current
      end
      raw
    end

    def changed_names
      application.changes.keys & (FIELDS + %w[rera_declared_at])
    end

    def extras_belong_to_city?
      application.extra_locality_ids.all? do |id|
        extra = Locality.active.find_by(id:)
        extra && extra.city_id == application.city_id && extra.id != application.locality_id
      end
    end

    def sync_firm
      firm = application.firm
      previous = Current.firm
      Current.firm = firm
      firm.update!(
        name: application.firm_name,
        legal_name: application.legal_name,
        primary_contact_name: application.applicant_name,
        address_line1: application.address_line1,
        address_line2: application.address_line2,
        city_id: application.city_id,
        locality_id: application.locality_id,
        pincode: application.pincode,
        pan: application.pan,
        gst_number: application.gst_number,
        rera_number: application.rera_registered? ? application.rera_number : nil,
        rera_valid_till: application.rera_registered? ? application.rera_valid_till : nil
      )
      firm.super_admin&.update!(name: application.applicant_name)
      firm.firm_localities.where.not(locality_id: application.extra_locality_ids).destroy_all
      present = firm.firm_localities.pluck(:locality_id)
      (application.extra_locality_ids - present).each do |locality_id|
        firm.firm_localities.create!(locality_id:)
      end
    ensure
      Current.firm = previous
    end
  end
end
