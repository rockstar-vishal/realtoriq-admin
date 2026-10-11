# frozen_string_literal: true

module Api
  module V1
    class FirmWebsiteController < AuthenticatedController
      wrap_parameters false
      before_action :require_super_admin

      def show
        render json: { website: FirmWebsiteSerializer.call(current_firm) }
      end

      def update
        result = Firms::UpdateWebsite.call(firm: current_firm, actor: current_user, attributes: website_params)
        unless result.ok?
          return render_error(result.error_code, result.error_message,
                              status: :unprocessable_content, details: result.errors.to_hash)
        end

        render json: { website: FirmWebsiteSerializer.call(result.firm.reload) }
      end

      private

      def website_params
        params.permit(
          :about, :website_phone, :website_enabled, :address_line1, :address_line2,
          :city_id, :locality_id, :pincode, :lat, :lng, :google_place_id,
          :logo_signed_id, :remove_logo
        )
      end
    end
  end
end
