# frozen_string_literal: true

module Facebook
  # The installed app opens this with a one-time ticket. No broker session.
  # A good ticket is spent and the browser goes to Facebook. Anything else
  # goes to the public done page.
  class StartController < ActionController::API
    def show
      attempt = FacebookOauthAttempt.usable_handoff(ticket_param)
      url = authorization_url(attempt) if attempt
      if url && FacebookOauthAttempt.claim_handoff!(attempt)
        redirect_to url, allow_other_host: true
      else
        redirect_to done_url("expired"), allow_other_host: true
      end
    rescue Errors::ConfigurationError
      head :bad_gateway
    end

    private

    def ticket_param
      params[:ticket].is_a?(String) ? params[:ticket] : ""
    end

    def authorization_url(attempt)
      OauthService.new.authorization_url(state: State.encrypt(attempt.id))
    end

    def done_url(result)
      "#{Credentials.web_origin}/facebook/done?result=#{result}"
    end
  end
end
