# frozen_string_literal: true

module Facebook
  # Reads the Meta app settings from Rails credentials. Never logs the values.
  module Credentials
    REQUIRED = %i[app_id app_secret configuration_id verify_token web_origin].freeze

    module_function

    def [](key)
      Rails.application.credentials.dig(:facebook, key)
    end

    def fetch!(key)
      value = self[key]
      raise Errors::ConfigurationError, "Missing Facebook credential: #{key}" if value.blank?

      value
    end

    def configured?
      REQUIRED.all? { |key| self[key].present? }
    end

    def system_user_login?
      self[:access_token_kind].to_s == "system_user"
    end

    # Origin only. The callback never redirects anywhere else.
    def web_origin
      raw = fetch!(:web_origin).to_s.strip.sub(%r{/\z}, "")
      uri = URI.parse(raw)
      unless uri.is_a?(URI::HTTP) && uri.host.present? && (uri.path.blank? || uri.path == "/") && uri.user.nil?
        raise Errors::ConfigurationError, "Facebook credential web_origin must be an origin"
      end

      "#{uri.scheme}://#{uri.host}#{port_suffix(uri)}"
    end

    def port_suffix(uri)
      return "" if uri.port == uri.default_port

      ":#{uri.port}"
    end
    private_class_method :port_suffix
  end
end
