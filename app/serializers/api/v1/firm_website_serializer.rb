# frozen_string_literal: true

module Api
  module V1
    module FirmWebsiteSerializer
      module_function

      def call(firm)
        mobile = ContactChannel.unscoped.find_by(firm_id: firm.id, kind: "mobile")
        {
          enabled: firm.website_enabled,
          url: firm.website_public? ? Sites::Host.public_url(firm, "/") : nil,
          about: firm.about,
          logo_url: firm.public_logo? ? BlobUrl.call(firm.logo) : nil,
          initials: Sites::PagesController.helpers.site_initials(firm),
          address_line1: firm.address_line1,
          address_line2: firm.address_line2,
          city_id: firm.city_id,
          locality_id: firm.locality_id,
          city: firm.city&.name,
          locality: firm.locality&.name,
          pincode: firm.pincode,
          lat: firm.lat&.to_f,
          lng: firm.lng&.to_f,
          google_place_id: firm.google_place_id,
          phone: firm.website_phone,
          suggested_phone: firm.website_phone.present? ? nil : mobile&.value
        }
      end
    end
  end
end
