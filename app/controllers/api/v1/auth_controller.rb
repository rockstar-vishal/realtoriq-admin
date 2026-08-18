# frozen_string_literal: true

module Api
  module V1
    # Sign-in. No passwords and no self-signup anywhere: ops create the account,
    # and possession of the mobile is the credential.
    class AuthController < BaseController
      # The unauthenticated surface, so it carries its own rate limit on top of
      # the per-user lockout. See config/application.rb — strict in production,
      # loose in development so a test loop doesn't lock itself out.
      rate_limit to: Rails.configuration.x.otp_rate_limit, within: 5.minutes, only: :request_code,
        with: -> { render_error("rate_limited", "Too many attempts. Try again shortly.", status: :too_many_requests) }

      def request_code
        user = User.find_for_sign_in(mobile: params[:mobile])

        # The design's "This number isn't registered" wall. Said plainly because
        # there is no self-signup — a stranger learning that a number is not
        # registered gains nothing they can act on.
        return render_error("not_registered", "This number isn't registered. Channel partners are onboarded by the sales team.", status: :not_found) if user.nil?

        return render_error("account_disabled", "This account has been disabled.", status: :forbidden) if user.disabled?

        if user.locked_out?
          return render_error("otp_locked", "Too many incorrect codes. Try again in 30 minutes.",
                              status: :too_many_requests,
                              details: { retry_after: user.otp_locked_until })
        end

        record, code = OneTimeCode.issue!(
          purpose: "login", destination: user.mobile, user:, ip: request.remote_ip
        )

        Notifications::Deliverer.current.deliver_code(
          transport: :sms, destination: user.mobile, code:, purpose: "login"
        )

        render json: {
          request_id: record.id,
          sent_to: Phone.mask(user.mobile),
          expires_in: (record.expires_at - Time.current).to_i,
          attempts_allowed: User::MAX_FAILED_OTP_ATTEMPTS
        }, status: :ok
      rescue Notifications::Deliverer::DeliveryError
        render_error("delivery_failed", "Couldn't send the code right now. Try again shortly.",
                     status: :service_unavailable)
      end

      def verify
        record = OneTimeCode.login.find_by(id: params.require(:request_id))
        return render_error("invalid_code", "That code has expired. Request a new one.", status: :unauthorized) if record.nil?

        user = record.user
        return render_error("otp_locked", "Too many incorrect codes. Try again in 30 minutes.", status: :too_many_requests) if user.locked_out?

        unless record.verify(params.require(:code))
          user.register_failed_otp_attempt!
          return render_error("invalid_code", "That code isn't right.", status: :unauthorized,
                              details: { attempts_left: [ User::MAX_FAILED_OTP_ATTEMPTS - user.failed_otp_attempts, 0 ].max })
        end

        # State checks come after the code is proven, so an unauthenticated
        # caller can't probe which firms are suspended.
        if user.firm.suspended?
          return render_error("account_suspended", "This account is suspended. Contact your RM.", status: :forbidden)
        end

        user.clear_otp_lockout!

        session, refresh_token = AuthSession.start!(
          user:, device: device_params, ip: request.remote_ip, user_agent: request.user_agent
        )

        user.update_column(:last_seen_at, Time.current)
        AuditEvent.record!(subject: user, firm: user.firm, actor: user, action: "user.signed_in",
                           metadata: { device: device_params[:device_name] })

        render json: token_payload(user, session, refresh_token), status: :ok
      end

      def refresh
        token = params.require(:refresh_token)
        session = AuthSession.across_firms.live.find_by(refresh_token_digest: AuthSession.digest(token))

        return render_error("unauthorized", "Sign in again.", status: :unauthorized) if session.nil?

        user = session.user
        return render_error("account_disabled", "This account has been disabled.", status: :forbidden) if user.disabled?
        return render_error("account_suspended", "This account is suspended.", status: :forbidden) if user.firm.suspended?

        rotated = session.rotate_refresh_token!

        render json: token_payload(user, session, rotated), status: :ok
      end

      def sign_out
        token = params[:refresh_token]
        session = token.present? &&
          AuthSession.across_firms.live.find_by(refresh_token_digest: AuthSession.digest(token))

        session.revoke!("signed_out") if session

        # Always 204: whether that token was live is not something an
        # unauthenticated caller needs told.
        head :no_content
      end

      private

      def device_params
        params.fetch(:device, {}).permit(:device_id, :device_name, :platform, :app_version).to_h.symbolize_keys
      rescue ActionController::UnpermittedParameters
        {}
      end

      def token_payload(user, session, refresh_token)
        subscription = user.firm.current_subscription

        {
          access_token: ApiAuth::Jwt.encode_access(user:, session:),
          refresh_token:,
          expires_in: ApiAuth::Jwt::ACCESS_TTL.to_i,
          user: {
            id: user.id, name: user.name, email: user.email,
            mobile: user.mobile, role: user.role
          },
          firm: {
            id: user.firm.id, name: user.firm.name, code: user.firm.code,
            status: user.firm.status
          },
          subscription: subscription && {
            plan: subscription.plan.name,
            status: subscription.status,
            entitled: subscription.entitled?,
            renews_on: subscription.current_period_end
          }
        }
      end
    end
  end
end
