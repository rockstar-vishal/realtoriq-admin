# frozen_string_literal: true

module Realtoriq
  # Shared with turbo-rails8. webhook_secret verifies inbound pushes.
  # turbo_public_origin is the host of GET /m/:code, with no trailing slash.
  module Credentials
    module_function

    def webhook_secret
      Rails.application.credentials.dig(:realtoriq, :webhook_secret).to_s
    end

    def turbo_public_origin
      Rails.application.credentials.dig(:realtoriq, :turbo_public_origin).to_s.strip.sub(%r{/\z}, "")
    end

    # Same secret turbo checks on POST/GET /realtoriq/visit_passes.
    def inbound_token
      Rails.application.credentials.dig(:realtoriq, :inbound_token).to_s
    end

    # API host for visit passes. Falls back to the public microsite origin,
    # which is the same Rails app unless a separate host is configured.
    def turbo_api_origin
      configured = Rails.application.credentials.dig(:realtoriq, :turbo_api_origin).to_s.strip
      (configured.presence || turbo_public_origin).sub(%r{/\z}, "")
    end
  end
end
