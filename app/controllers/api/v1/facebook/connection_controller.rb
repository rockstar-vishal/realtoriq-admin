# frozen_string_literal: true

module Api
  module V1
    module Facebook
      class ConnectionController < BaseController
        def destroy
          connection = current_connection
          return not_found if connection.nil?

          ::Facebook::Disconnect.call(connection:, actor: current_user)
          render json: integration_payload
        end

        def health_check
          connection = current_connection
          return not_found if connection.nil?

          ok = ::Facebook::TokenManager.health_check!(connection)
          render json: { ok:, connection: integration_payload[:connection] }
        end

        private

        def current_connection
          ::FacebookConnection.current_for(current_firm)
        end
      end
    end
  end
end
