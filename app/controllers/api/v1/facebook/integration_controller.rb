# frozen_string_literal: true

module Api
  module V1
    module Facebook
      class IntegrationController < BaseController
        def show
          render json: integration_payload
        end
      end
    end
  end
end
