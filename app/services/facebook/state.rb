# frozen_string_literal: true

module Facebook
  # Signed payload for the Facebook redirect. It carries only the attempt id.
  class State
    def self.encrypt(attempt_id)
      encryptor.encrypt_and_sign({ "attempt_id" => attempt_id }, expires_in: 15.minutes)
    end

    def self.decrypt(token)
      data = encryptor.decrypt_and_verify(token.to_s)
      return if data.blank?

      data = data.stringify_keys if data.respond_to?(:stringify_keys)
      data["attempt_id"].presence
    rescue ActiveSupport::MessageEncryptor::InvalidMessage, ActiveSupport::MessageVerifier::InvalidSignature
      nil
    end

    def self.encryptor
      key = Rails.application.key_generator.generate_key("facebook_oauth_state", 32)
      ActiveSupport::MessageEncryptor.new(key, cipher: "aes-256-gcm")
    end
  end
end
