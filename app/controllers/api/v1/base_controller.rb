# frozen_string_literal: true

module Api
  module V1
    # One error envelope for the whole API: { error: { code, message, details } }.
    # The React app switches on `code`, never on the prose.
    #
    # **Unknown and misshapen parameters are ignored, deliberately.** Rails drops
    # a key that isn't permitted, and drops an array value handed to a
    # scalar-permitted key — both silently. That has already cost the mobile team
    # a session (`property_type_id` sent as an array produced a confusing 422;
    # `possession_up_to` instead of `possession_by` produced a 201 with no date
    # stored).
    #
    # `action_on_unpermitted_parameters = :raise` would turn both into an
    # immediate 400 naming the key. It was considered and **rejected**: it breaks
    # every client that sends a stray field, which is exactly what a mobile app
    # mid-rollout does, and forward compatibility is worth more here than a
    # louder failure.
    #
    # The mitigation is documentation instead — docs/api.md marks which params
    # are arrays and which are scalars, and the Postman collection sends the
    # complete permitted set for every endpoint, so there is a working example
    # of each. Keep both current when you add a parameter.
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
      before_action :normalise_page

      private

      # Pagy raises on page 0, a negative page, or a non-numeric one, and the
      # raise surfaced as a 500 HTML page on every index endpoint. A client
      # sending `page=0` for its first page, or an empty string from an unset
      # form field, is making an ordinary mistake and should get page one.
      #
      # `Pagy::DEFAULT[:overflow] = :last_page` only covers the other end —
      # a page past the last one.
      def normalise_page
        raw = params[:page]
        return if raw.nil?

        params[:page] = raw.is_a?(String) || raw.is_a?(Numeric) ? [ raw.to_i, 1 ].max : 1
      end

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
