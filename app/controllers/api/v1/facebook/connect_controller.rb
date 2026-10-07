# frozen_string_literal: true

module Api
  module V1
    module Facebook
      class ConnectController < BaseController
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
          url = ::Facebook::OauthService.new.authorization_url(state: ::Facebook::State.encrypt(attempt.id))
          render json: { authorization_url: url, attempt_id: attempt.id }
        rescue ::Facebook::Errors::ConfigurationError
          render_facebook_error("not_configured")
        end
      end
    end
  end
end
