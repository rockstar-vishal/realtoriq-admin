# frozen_string_literal: true

module Facebook
  # Meta's leadgen webhook. No broker session. A bad signature is refused.
  # A database error is the only reason this returns 500.
  class WebhooksController < ActionController::API
    MAX_BODY = 1.megabyte

    def verify
      mode = hub("mode")
      token = hub("verify_token")
      challenge = hub("challenge")
      if mode == "subscribe" && token_matches?(token)
        render plain: challenge.to_s, status: :ok
      else
        head :forbidden
      end
    end

    def receive
      body = request.raw_post.to_s
      return head :content_too_large if body.bytesize > MAX_BODY
      return head :unauthorized unless signature_matches?(body)

      payload = JSON.parse(body)
      return head :bad_request unless payload.is_a?(Hash)

      failed = false
      Array(payload["entry"]).each do |entry|
        Array(entry["changes"]).each do |change|
          next unless change.is_a?(Hash) && change["field"] == "leadgen"

          RouteLead.call(change["value"])
        rescue ActiveRecord::ActiveRecordError
          failed = true
        end
      end
      failed ? head(:internal_server_error) : head(:ok)
    rescue JSON::ParserError
      head :bad_request
    end

    private

    def hub(name)
      params["hub.#{name}"].presence || params.dig(:hub, name)
    end

    def token_matches?(token)
      expected = Credentials[:verify_token].to_s
      given = token.to_s
      return false if expected.blank? || given.blank? || given.bytesize != expected.bytesize

      ActiveSupport::SecurityUtils.secure_compare(given, expected)
    end

    def signature_matches?(body)
      header = request.headers["X-Hub-Signature-256"].to_s
      secret = Credentials[:app_secret].to_s
      return false if header.blank? || secret.blank?

      expected = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, body)}"
      return false unless header.bytesize == expected.bytesize

      ActiveSupport::SecurityUtils.secure_compare(header, expected)
    end
  end
end
