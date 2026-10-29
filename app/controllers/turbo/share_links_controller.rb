# frozen_string_literal: true

module Turbo
  # LaunchIQ looks up the broker strip for a microsite link. The bearer is
  # realtoriq.inbound_token. Errors are a string, the same shape as the events
  # webhook, because LaunchIQ is the caller.
  class ShareLinksController < ActionController::API
    include ActiveStorage::SetCurrent

    LIMIT = 600
    WINDOW = 1.minute

    before_action :enforce_rate_limit
    before_action :authenticate!

    def show
      link = ProjectShareLink.across_firms.find_by(token: params[:token].to_s)
      firm = link&.firm
      return render json: { error: "Not found" }, status: :not_found if link.nil? || firm.nil? || !firm.active?

      project = Project.unscoped.find_by(id: link.project_id)
      render json: {
        firm: {
          name: firm.name,
          mobile: mobile_for(firm),
          whatsapp: whatsapp_for(firm),
          rera_number: firm.rera_number.presence,
          logo_url: logo_url(firm)
        },
        project_code: project&.external_ref
      }
    end

    private

    def authenticate!
      given = bearer
      expected = Realtoriq::Credentials.inbound_token.to_s
      return if given.present? && expected.present? && secure_match?(given, expected)

      render json: { error: "Unauthorized" }, status: :unauthorized
    end

    def enforce_rate_limit
      count = Rails.cache.increment("rate-limit/share-link/#{request.remote_ip}", 1, expires_in: WINDOW)
      return if count.is_a?(Integer) && count <= LIMIT
      return if count.nil? && Rails.cache.is_a?(ActiveSupport::Cache::NullStore)

      render json: { error: "Too many requests" }, status: :too_many_requests
    end

    def secure_match?(given, expected)
      ActiveSupport::SecurityUtils.secure_compare(
        Digest::SHA256.hexdigest(given),
        Digest::SHA256.hexdigest(expected)
      )
    end

    def bearer
      header = request.authorization.to_s
      return unless header.start_with?("Bearer ")

      header.delete_prefix("Bearer ").presence
    end

    def mobile_for(firm)
      Marketing::FirmContacts.new(firm).mobile
    end

    def whatsapp_for(firm)
      Marketing::FirmContacts.new(firm).whatsapp
    end

    def logo_url(firm)
      return unless firm.logo.attached? && firm.logo.blob.variable?

      Api::V1::BlobUrl.variant(firm.logo, :card)
    end
  end
end
