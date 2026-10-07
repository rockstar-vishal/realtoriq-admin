# frozen_string_literal: true

module Facebook
  module Errors
    class Base < StandardError
      attr_reader :fb_error_code, :fb_error_subcode, :fb_error_type

      def initialize(message = nil, fb_error_code: nil, fb_error_subcode: nil, fb_error_type: nil)
        super(message)
        @fb_error_code = fb_error_code&.to_s
        @fb_error_subcode = fb_error_subcode&.to_s
        @fb_error_type = fb_error_type
      end
    end

    class TokenInvalidError < Base; end
    class RateLimitError < Base; end
    class LeadFetchError < Base; end
    class WebhookSubscriptionError < Base; end
    class OAuthError < Base; end

    # A system-user configuration returned a token that expires in under a day.
    class ShortLivedTokenError < OAuthError; end

    class ConfigurationError < Base; end

    INVALID_TOKEN_CODES = %w[190 102 463 467 368].freeze
    RATE_LIMIT_CODES = %w[4 17 32 613].freeze

    class << self
      def from_koala(error)
        code = error.fb_error_code&.to_s
        subcode = error.fb_error_subcode&.to_s
        type = error.fb_error_type
        # Koala's own message can contain the request URL and the token.
        message = error.respond_to?(:fb_error_message) ? error.fb_error_message.presence : nil
        message ||= "Facebook request failed"

        if INVALID_TOKEN_CODES.include?(code)
          TokenInvalidError.new(message, fb_error_code: code, fb_error_subcode: subcode, fb_error_type: type)
        elsif RATE_LIMIT_CODES.include?(code)
          RateLimitError.new(message, fb_error_code: code, fb_error_subcode: subcode, fb_error_type: type)
        else
          Base.new(message, fb_error_code: code, fb_error_subcode: subcode, fb_error_type: type)
        end
      end
    end
  end
end
