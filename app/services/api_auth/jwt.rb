# frozen_string_literal: true

module ApiAuth
  # Access tokens for the broker API.
  #
  # Short-lived (15 minutes) and paired with a database-backed refresh token, so
  # revoking a device takes effect within one token lifetime. A long-lived JWT
  # would be unrevokable, which is exactly what "device limit reached" and
  # "account suspended" need to be able to do.
  module Jwt
    class Error < StandardError; end

    ALGORITHM = "HS256"
    ACCESS_TTL = 15.minutes
    ISSUER = "realtoriq"

    class << self
      def encode_access(user:, session:)
        now = Time.current.to_i

        payload = {
          sub: user.id,
          firm_id: user.firm_id,
          session_id: session.id,
          role: user.role,
          type: "access",
          iss: ISSUER,
          iat: now,
          exp: now + ACCESS_TTL.to_i
        }

        JWT.encode(payload, secret, ALGORITHM)
      end

      def decode(token)
        payload, = JWT.decode(token, secret, true, algorithm: ALGORITHM, iss: ISSUER, verify_iss: true)
        payload
      rescue JWT::DecodeError => e
        # Deliberately opaque: the caller gets "unauthorized", never a hint about
        # which part of the token failed.
        raise Error, e.message
      end

      private

      def secret
        Rails.application.credentials.jwt_secret.presence ||
          Rails.application.secret_key_base
      end
    end
  end
end
