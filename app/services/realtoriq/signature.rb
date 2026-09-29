# frozen_string_literal: true

module Realtoriq
  # turbo signs JSON.generate(payload) and sends X-RealtorIQ-Signature: sha256=<hex>.
  class Signature
    def self.valid?(body, header)
      secret = Credentials.webhook_secret
      provided = header.to_s.sub(/\Asha256=/i, "").strip
      return false if secret.blank? || provided.blank?
      return false unless provided.bytesize == secret_hex_size(secret, body)

      expected = OpenSSL::HMAC.hexdigest("SHA256", secret, body.to_s)
      ActiveSupport::SecurityUtils.secure_compare(provided, expected)
    end

    def self.secret_hex_size(secret, body)
      OpenSSL::HMAC.hexdigest("SHA256", secret, body.to_s).bytesize
    end
    private_class_method :secret_hex_size
  end
end
