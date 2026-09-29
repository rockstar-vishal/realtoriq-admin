# frozen_string_literal: true

require "net/http"
require "json"

module Realtoriq
  # Server-to-server calls to turbo. HTTPS only. The bearer token is
  # realtoriq.inbound_token and is never logged.
  class TurboClient
    class Error < StandardError
      attr_reader :status, :payload

      def initialize(message, status: nil, payload: nil)
        @status = status
        @payload = payload
        super(message)
      end
    end

    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 15

    def self.create_visit_pass(body)
      new.post("/realtoriq/visit_passes", body)
    end

    def self.fetch_visit_pass(code, firm_id)
      query = URI.encode_www_form(realtoriq_firm_id: firm_id)
      encoded = URI.encode_www_form_component(code)
      new.get("/realtoriq/visit_passes/#{encoded}?#{query}")
    end

    def post(path, body)
      request(Net::HTTP::Post.new(endpoint(path)), body)
    end

    def get(path)
      request(Net::HTTP::Get.new(endpoint(path)), nil)
    end

    private

    def request(http_request, body)
      uri = http_request.uri
      raise Error, "LaunchIQ origin must be https" unless uri.is_a?(URI::HTTPS)

      token = Credentials.inbound_token
      raise Error, "Set realtoriq.inbound_token before calling LaunchIQ" if token.blank?

      http_request["Authorization"] = "Bearer #{token}"
      http_request["Accept"] = "application/json"
      if body
        http_request["Content-Type"] = "application/json"
        http_request.body = JSON.generate(body)
      end

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
        open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
        http.request(http_request)
      end

      payload = parse(response.body)
      return payload if response.is_a?(Net::HTTPSuccess)

      raise Error.new(message_from(payload, response.code), status: response.code.to_i, payload:)
    rescue Error
      raise
    rescue StandardError => e
      raise Error, "Could not reach LaunchIQ (#{e.class})"
    end

    def endpoint(path)
      origin = Credentials.turbo_api_origin
      raise Error, "Set realtoriq.turbo_public_origin before calling LaunchIQ" if origin.blank?

      URI.parse("#{origin}#{path}")
    end

    def parse(raw)
      return {} if raw.blank?

      JSON.parse(raw)
    rescue JSON::ParserError
      {}
    end

    def message_from(payload, code)
      if payload.is_a?(Hash)
        return payload["error"] if payload["error"].is_a?(String)

        errors = payload["errors"]
        return errors.join(", ") if errors.is_a?(Array) && errors.all?(String)
      end

      "LaunchIQ returned HTTP #{code}"
    end
  end
end
