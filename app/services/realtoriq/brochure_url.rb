# frozen_string_literal: true

module Realtoriq
  # The link a customer can open.
  #
  # A marketplace brochure stays on LaunchIQ. The share text points at
  # GET /realtoriq/brochures/:code there, which serves the file. This app
  # does not download it.
  #
  # A firm's own upload is served from this app's /realtoriq/brochures path.
  module BrochureUrl
    LAUNCHIQ_CODE = /\APR[0-9A-F]{6}\z/

    module_function

    def for(project)
      launched = launchiq_url(project)
      return launched if launched
      return nil unless project.brochure.attached?

      Rails.application.routes.url_helpers.realtoriq_brochure_url(project.code, format: :pdf)
    end

    def launchiq_url(project)
      return unless project.brochure_source_url.present?
      return unless project.external_ref.to_s.match?(LAUNCHIQ_CODE)

      origin = Credentials.turbo_public_origin
      return project.brochure_source_url if origin.blank?

      "#{origin}/realtoriq/brochures/#{project.external_ref.upcase}"
    end
  end
end
