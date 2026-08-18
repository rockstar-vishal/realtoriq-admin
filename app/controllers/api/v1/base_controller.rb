# frozen_string_literal: true

module Api
  module V1
    # One error envelope for the whole API: { error: { code, message, details } }.
    # The React app switches on `code`, never on the prose.
    class BaseController < ActionController::API
      include Pagy::Backend

      # Active Storage builds absolute URLs and needs a host to do it. Its own
      # controllers get this from ActiveStorage::BaseController; ours don't
      # inherit from that, so without it any blob URL raises "Missing host to
      # link to!" — including /me's logo_url the moment a firm has a logo.
      include ActiveStorage::SetCurrent

      rescue_from ActiveRecord::RecordNotFound, with: :not_found
      rescue_from ActionController::ParameterMissing, with: :parameter_missing

      before_action :set_request_context

      private

      def set_request_context
        Current.request_ip = request.remote_ip
        Current.user_agent = request.user_agent
      end

      def render_error(code, message, status:, details: nil)
        payload = { code:, message: }
        payload[:details] = details if details.present?

        render json: { error: payload }, status:
      end

      def not_found
        render_error("not_found", "Not found", status: :not_found)
      end

      def parameter_missing(exception)
        render_error("invalid_request", "Missing parameter: #{exception.param}", status: :bad_request)
      end

      def pagination_meta(pagy)
        { page: pagy.page, per_page: pagy.limit, total_count: pagy.count, total_pages: pagy.pages }
      end
    end
  end
end
