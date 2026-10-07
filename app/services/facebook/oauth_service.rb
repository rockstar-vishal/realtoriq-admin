# frozen_string_literal: true

require "koala"

module Facebook
  # Facebook Login for Business. Permissions live in the Meta configuration,
  # not in a scope parameter.
  class OauthService
    def self.system_user_login?
      Credentials.system_user_login?
    end

    def initialize
      @app_id = Credentials.fetch!(:app_id)
      @app_secret = Credentials.fetch!(:app_secret)
      @configuration_id = Credentials.fetch!(:configuration_id)
    end

    def system_user_login?
      self.class.system_user_login?
    end

    def authorization_url(state:)
      options = { state:, config_id: @configuration_id }
      if system_user_login?
        options[:response_type] = "code"
        options[:override_default_response_type] = "true"
      end
      oauth_client.url_for_oauth_code(options)
    end

    def exchange_code(code:)
      token_info = fetch_token_info(code)
      token = token_info.is_a?(Hash) ? token_info["access_token"] : nil
      raise Errors::OAuthError, "Facebook did not return an access token" if token.blank?
      if system_user_login? && short_lived_token?(token_info["expires_in"])
        raise Errors::ShortLivedTokenError, "Facebook returned a short-lived token"
      end

      user_api = GraphApiClient.new(access_token: token)
      me = user_api.verify_token(fields: profile_fields)
      raise Errors::OAuthError, "Facebook did not return an account id" if me["id"].blank?

      {
        long_lived_token: token,
        expires_at: parse_token_expires_at(token_info["expires_in"]),
        fb_user_id: me["id"],
        fb_user_name: display_name(user_api, me),
        client_business_id: me["client_business_id"].presence,
        token_kind: system_user_login? ? "system_access" : "user_access",
        pages: user_api.list_pages
      }
    rescue Koala::Facebook::OAuthTokenRequestError => e
      raise Errors::OAuthError.new("Token exchange failed", fb_error_code: e.fb_error_code)
    rescue Errors::Base
      raise
    rescue StandardError
      raise Errors::OAuthError, "OAuth error"
    end

    def app_access_token
      "#{@app_id}|#{@app_secret}"
    end

    private

    def oauth_client
      @oauth_client ||= Koala::Facebook::OAuth.new(@app_id, @app_secret, callback_url)
    end

    def callback_url
      Rails.application.routes.url_helpers.facebook_callback_url
    end

    def fetch_token_info(code)
      if system_user_login?
        oauth_client.get_access_token_info(code)
      else
        short_lived = oauth_client.get_access_token(code)
        oauth_client.exchange_access_token_info(short_lived)
      end
    end

    def profile_fields
      system_user_login? ? "id,client_business_id" : "id,name"
    end

    def display_name(user_api, me)
      return me["name"] unless system_user_login?

      user_api.business_name(me["client_business_id"]).presence || "System user"
    end

    def short_lived_token?(expires_in)
      seconds = expires_in.to_i
      seconds.positive? && seconds < 1.day.to_i
    end

    def parse_token_expires_at(expires_in)
      seconds = expires_in.to_i
      return nil if seconds <= 0

      Time.current + seconds.seconds
    end
  end
end
