# frozen_string_literal: true

module Sites
  # reCAPTCHA v2 checkbox. The secret never leaves the server. A timeout or
  # any other failure refuses the enquiry. Development without a secret still
  # accepts a post so a local firm site can be tried; test accepts only the
  # token "pass".
  class Recaptcha
    VERIFY_URL = URI("https://www.google.com/recaptcha/api/siteverify")
    TIMEOUT = 3

    def self.accepted?(token, remote_ip:, hostname:)
      return token.to_s == "pass" if Rails.env.test?

      secret = Realtoriq::Credentials.recaptcha_secret
      return Rails.env.development? if secret.blank?
      return false if token.blank? || hostname.blank?

      payload = verify(secret, token, remote_ip)
      payload.is_a?(Hash) && payload["success"] == true && host_matches?(payload["hostname"], hostname)
    end

    # The key is registered for the parent domain, so Google will mint a token
    # for any subdomain. This request's host is the only one we accept.
    def self.host_matches?(returned, expected)
      actual = returned.to_s.downcase.split(":").first
      wanted = expected.to_s.downcase.split(":").first
      actual.present? && actual == wanted
    end

    def self.verify(secret, token, remote_ip)
      response = Net::HTTP.start(
        VERIFY_URL.host, VERIFY_URL.port,
        use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT
      ) do |http|
        request = Net::HTTP::Post.new(VERIFY_URL)
        request.set_form_data("secret" => secret, "response" => token, "remoteip" => remote_ip.to_s)
        http.request(request)
      end
      return {} unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue StandardError
      {}
    end
    private_class_method :host_matches?, :verify
  end
end
