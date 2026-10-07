# frozen_string_literal: true

module Api
  module V1
    module Facebook
      class BaseController < AuthenticatedController
        before_action :require_super_admin

        private

        def integration_payload(warnings: nil)
          payload = ::Facebook::IntegrationPayload.call(firm: current_firm)
          payload[:warnings] = warnings unless warnings.nil?
          payload
        end

        def render_facebook_error(code, details: nil)
          render_error(code, ERRORS.fetch(code, "Could not update Facebook."), status: :unprocessable_entity, details:)
        end

        ERRORS = {
          "expired" => "This Facebook login expired. Click Connect again.",
          "not_yours" => "This Facebook login was started in another browser or by another user. Click Connect again.",
          "already_used" => "This Facebook login was already used. Click Connect again.",
          "denied" => "Facebook denied the connection. Click Connect again.",
          "exchange_failed" => "Could not connect Facebook. Click Connect again.",
          "short_lived_token" => "This Facebook setup gives short-lived access; contact support",
          "no_pages" => "Facebook didn't share any Pages. Reconnect and tick every Page.",
          "missing_subscribed_pages" => "Facebook did not return every Page that is subscribed. The current connection was left unchanged.",
          "wrong_browser" => "This Facebook login was started in another browser or by another user. Click Connect again.",
          "already_connected" => "Facebook is already connected. Refresh the page and try again.",
          "page_taken" => "Every Page in this login is already connected to another firm.",
          "not_configured" => "Facebook isn't set up on this server yet.",
          "invalid_request" => "That Facebook request was incomplete."
        }.freeze
      end
    end
  end
end
