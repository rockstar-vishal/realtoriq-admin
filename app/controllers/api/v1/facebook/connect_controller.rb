# frozen_string_literal: true

module Api
  module V1
    module Facebook
      class ConnectController < BaseController
        # The owner is the only person who can start a connect. Status is
        # still limited to that same user: every other signed-in user is 404,
        # not a role error that would confirm the attempt exists.
        skip_before_action :require_super_admin, only: :show

        def create
          nonce = params[:nonce].to_s
          if nonce.length < 32
            return render_facebook_error("invalid_request")
          end
          unless ::Facebook::Credentials.configured?
            return render_facebook_error("not_configured")
          end

          attempt = FacebookOauthAttempt.create!(
            firm: current_firm,
            user: current_user,
            nonce_digest: Digest::SHA256.hexdigest(nonce),
            status: "started",
            expires_at: 15.minutes.from_now
          )
          state = ::Facebook::State.encrypt(attempt.id)
          url = ::Facebook::OauthService.new.authorization_url(state:)
          payload = { authorization_url: url, attempt_id: attempt.id }
          payload[:handoff_url] = handoff_url(attempt) if handoff?
          render json: payload
        rescue ::Facebook::Errors::ConfigurationError
          render_facebook_error("not_configured")
        end

        def show
          attempt = FacebookOauthAttempt.across_firms.find_by(id: params[:attempt_id])
          return not_found unless attempt&.user_id == current_user.id && attempt.firm_id == current_firm.id

          render json: {
            status: attempt.status,
            error_code: attempt.error_code,
            expires_at: attempt.expires_at.iso8601
          }
        end

        private

        def handoff?
          ActiveModel::Type::Boolean.new.cast(params[:handoff])
        end

        # 32 bytes, base64url. The row keeps the digest. The ticket itself is
        # only in this response, and the log filter drops it if it comes back
        # as a query parameter.
        def handoff_url(attempt)
          ticket = SecureRandom.urlsafe_base64(32)
          attempt.update!(
            handoff: true,
            handoff_ticket_digest: Digest::SHA256.hexdigest(ticket),
            handoff_expires_at: 10.minutes.from_now
          )
          "#{::Facebook::Credentials.web_origin}/facebook/start?ticket=#{ticket}"
        end
      end
    end
  end
end
