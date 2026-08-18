# frozen_string_literal: true

module Api
  module V1
    # Everything behind sign-in.
    #
    # This is where the tenant is established, and the only acceptable source is
    # the verified JWT — never a header, param or subdomain the client controls.
    class AuthenticatedController < BaseController
      before_action :authenticate!
      before_action :enforce_account_state

      private

      def authenticate!
        token = bearer_token
        return unauthorized if token.blank?

        payload = ApiAuth::Jwt.decode(token)
        return unauthorized unless payload["type"] == "access"

        # The session must still exist and be live — this is what makes a
        # revoked device stop working before its access token expires.
        session = AuthSession.across_firms.live.find_by(id: payload["session_id"])
        return unauthorized if session.nil?

        user = session.user
        return unauthorized if user.nil? || user.disabled?

        establish_tenant(user, session)
      rescue ApiAuth::Jwt::Error
        unauthorized
      end

      def establish_tenant(user, session)
        @current_session = session
        @current_user = user
        Current.firm = user.firm
        Current.user = user
        session.touch_used!
      end

      # Blocked states from the design, as codes the app can switch on.
      def enforce_account_state
        if current_firm.suspended?
          return render_error("account_suspended", "This account is suspended. Contact your RM.",
                              status: :forbidden)
        end

        return if current_firm.current_subscription&.entitled?

        render_error("subscription_lapsed", "The subscription for this firm has lapsed.",
                     status: :payment_required)
      end

      def require_super_admin
        return if current_user.super_admin?

        render_error("forbidden_role", "Only the firm's super admin can do this.", status: :forbidden)
      end

      def current_user = @current_user

      def current_firm = Current.firm

      def current_session = @current_session

      def bearer_token
        header = request.headers["Authorization"].to_s
        return nil unless header.start_with?("Bearer ")

        header.split(" ", 2).last.presence
      end

      def unauthorized
        render_error("unauthorized", "Sign in to continue.", status: :unauthorized)
      end
    end
  end
end
