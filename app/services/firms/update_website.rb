# frozen_string_literal: true

module Firms
  # Brand Website. Does not touch the firm name, RERA, PAN, GST, bank, or
  # the verified contact channels.
  class UpdateWebsite
    Result = Struct.new(:ok?, :firm, :errors, :error_code, :error_message, keyword_init: true)
    ABOUT_MAX = 2_000
    PLACE_ID = /\A[A-Za-z0-9_:.~-]{1,200}\z/

    def self.call(...)
      new(...).call
    end

    def initialize(firm:, actor:, attributes:)
      @firm = firm
      @actor = actor
      @attributes = attributes
    end

    def call
      previous_phone = firm.website_phone
      previous_enabled = firm.website_enabled
      assign
      return invalid if firm.errors.any?

      Firm.transaction do
        firm.save!
        attach_logo
        raise ActiveRecord::Rollback if firm.errors.any?
      end
      return invalid if firm.errors.any?

      audit_enabled(previous_enabled)
      audit_phone(previous_phone)
      Result.new(ok?: true, firm:)
    rescue ActiveRecord::RecordInvalid
      invalid
    end

    private

    attr_reader :firm, :actor, :attributes

    def assign
      if attributes.key?(:about)
        firm.about = attributes[:about].to_s.delete("\u0000").strip.presence
        firm.errors.add(:about, "is too long") if firm.about.to_s.length > ABOUT_MAX
      end
      assign_phone
      assign_address
      assign_pin
      firm.website_enabled = attributes[:website_enabled] if attributes.key?(:website_enabled)
    end

    def assign_phone
      raw = attributes[:website_phone]
      return unless attributes.key?(:website_phone)

      if raw.blank?
        firm.website_phone = nil
        return
      end

      phone = Phone.normalise(raw)
      unless phone&.match?(/\A\+91[6-9]\d{9}\z/)
        firm.errors.add(:website_phone, "must be an Indian mobile number")
        return
      end

      firm.website_phone = phone
    end

    def assign_address
      firm.address_line1 = attributes[:address_line1].to_s.strip.presence if attributes.key?(:address_line1)
      firm.address_line2 = attributes[:address_line2].to_s.strip.presence if attributes.key?(:address_line2)
      firm.pincode = attributes[:pincode].to_s.strip.presence if attributes.key?(:pincode)
      firm.city_id = attributes[:city_id].presence if attributes.key?(:city_id)
      firm.locality_id = attributes[:locality_id].presence if attributes.key?(:locality_id)
      return if firm.locality_id.blank?

      locality = Locality.find_by(id: firm.locality_id)
      if locality.nil? || (firm.city_id.present? && locality.city_id != firm.city_id)
        firm.errors.add(:locality_id, "does not belong to that city")
      elsif firm.city_id.blank?
        firm.city_id = locality.city_id
      end
    end

    def assign_pin
      return unless attributes.key?(:lat) || attributes.key?(:lng)

      unless attributes.key?(:lat) && attributes.key?(:lng)
        firm.errors.add(:base, "Latitude and longitude must be sent together")
        return
      end

      lat = attributes[:lat]
      lng = attributes[:lng]
      if lat.blank? && lng.blank?
        firm.lat = nil
        firm.lng = nil
        firm.google_place_id = nil
        return
      end

      firm.lat = lat
      firm.lng = lng
      place = attributes[:google_place_id].to_s.strip
      if place.present? && !place.match?(PLACE_ID)
        firm.errors.add(:google_place_id, "is not valid")
        return
      end

      firm.google_place_id = place.presence
    end

    def attach_logo
      if attributes[:remove_logo]
        firm.logo.purge_later if firm.logo.attached?
        return
      end

      signed_id = attributes[:logo_signed_id]
      return if signed_id.blank?

      accepted = Uploads::AcceptSignedId.new(signed_id:, firm:, purpose: "firm_logo").call
      unless accepted.ok?
        firm.errors.add(:logo, accepted.error_message)
        return
      end

      unless accepted.blob.content_type.in?(Sites::Catalog::RASTER)
        firm.errors.add(:logo, "must be a PNG, JPEG, or WebP")
        return
      end

      firm.logo.attach(accepted.blob)
    end

    def audit_enabled(previous)
      return if firm.website_enabled == previous

      AuditEvent.record!(
        subject: firm, actor:, action: firm.website_enabled? ? "website.enabled" : "website.disabled"
      )
    end

    def audit_phone(previous)
      return if firm.website_phone == previous

      AuditEvent.record!(subject: firm, actor:, action: "website.phone_changed", metadata: { changed: true })
    end

    def invalid
      Result.new(ok?: false, firm:, errors: firm.errors, error_code: "invalid",
                 error_message: firm.errors.full_messages.to_sentence)
    end
  end
end
