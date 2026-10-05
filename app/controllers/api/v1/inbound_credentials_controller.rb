# frozen_string_literal: true

module Api
  module V1
    # The firm owner copies the key and the four messages. Agents never see it.
    class InboundCredentialsController < AuthenticatedController
      before_action :require_super_admin

      def show
        render json: { inbound_credential: payload }
      end

      def rotate
        credential.rotate!(actor: current_user)
        render json: { inbound_credential: payload }
      end

      private

      def credential
        @credential ||= InboundCredential.ensure_for!(current_firm)
      end

      def payload
        Inbound::Instructions.payload(credential, request.base_url)
      end
    end
  end
end
