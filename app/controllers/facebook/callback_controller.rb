# frozen_string_literal: true

module Facebook
  # Meta's redirect. No broker session. The only redirect target is web_origin.
  class CallbackController < ActionController::API
    def show
      if params[:error].present?
        return deny(load_attempt)
      end

      attempt = load_attempt
      if attempt.nil? || !attempt.started? || attempt.expired?
        return redirect_expired
      end

      Current.set(firm: attempt.firm) do
        result = OauthService.new.exchange_code(code: params[:code])
        attempt.update!(
          status: "completed",
          error_code: nil,
          result: FacebookOauthAttempt.dump_oauth_result(result)
        )
      end
      redirect_attempt(attempt)
    rescue Errors::ShortLivedTokenError => e
      Log.error("oauth_callback", error_class: e.class.name, code: e.fb_error_code)
      fail_attempt(load_attempt, "short_lived_token")
    rescue Errors::Base => e
      Log.error("oauth_callback", error_class: e.class.name, code: e.fb_error_code)
      fail_attempt(load_attempt, "exchange_failed")
    end

    private

    def load_attempt
      id = State.decrypt(params[:state])
      return if id.blank?

      FacebookOauthAttempt.across_firms.find_by(id:)
    end

    def deny(attempt)
      return redirect_expired if attempt.nil? || !attempt.started?

      Current.set(firm: attempt.firm) { attempt.void!(error_code: "denied") }
      redirect_attempt(attempt)
    end

    def fail_attempt(attempt, code)
      return redirect_expired if attempt.nil? || !attempt.started?

      Current.set(firm: attempt.firm) { attempt.update!(status: "failed", error_code: code, result: nil) }
      redirect_attempt(attempt)
    end

    def redirect_expired
      redirect_facebook("facebook_error=expired")
    end

    def redirect_attempt(attempt)
      redirect_facebook("facebook_attempt=#{attempt.id}")
    end

    def redirect_facebook(query)
      redirect_to "#{Credentials.web_origin}/settings/facebook?#{query}", allow_other_host: true
    end
  end
end
