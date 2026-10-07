# frozen_string_literal: true

require "net/http"

module Notifications
  # MSG91 Flow API for SMS. WhatsApp goes through TwilioDeliverer. Email goes
  # through Action Mailer.
  #
  # Indian transactional SMS is DLT-regulated: the message body is registered
  # with the operator as a template and referenced by id, so this code never
  # composes it. The approved body is
  # "Thanks for Contacting Us! OTP to verify your phone number is ##var1## - KGEN",
  # and the recipient key has to match that variable name.
  #
  # The DLT entity id is stored under `msg91` for the record. The Flow API does
  # not take it: MSG91 maps the entity id to the sender on their panel.
  class Msg91Deliverer < Deliverer
    ENDPOINT = URI("https://control.msg91.com/api/v5/flow/").freeze
    TIMEOUT = 5
    CODE_VARIABLE = "var1"

    REQUIRED_CREDENTIALS = %i[auth_key sms_template_id sms_sender_id].freeze

    def deliver_code(transport:, destination:, code:, purpose:)
      raise DeliveryError, "Unknown transport #{transport}" unless transport == :sms
      raise DeliveryError, "A code needs a purpose" if purpose.blank?

      send_sms(destination, code)
      true
    end

    # Reports whether SMS can be sent, without sending anything. Used by
    # `bin/rails msg91:check`.
    def self.configuration_status
      settings = Rails.application.credentials.msg91 || {}
      missing = REQUIRED_CREDENTIALS.reject { |key| settings[key].present? }

      { sms: { ready: missing.empty?, missing: } }
    end

    private

    def send_sms(destination, code)
      settings = credentials

      # short_url stays off so MSG91 does not rewrite the DLT-approved text.
      post(ENDPOINT, settings, {
        template_id: settings[:sms_template_id],
        sender: settings[:sms_sender_id],
        short_url: "0",
        recipients: [ { mobiles: digits(destination), CODE_VARIABLE => code } ]
      })
    end

    def credentials
      settings = Rails.application.credentials.msg91 ||
        raise(DeliveryError, "MSG91 credentials are not configured")

      missing = REQUIRED_CREDENTIALS.reject { |key| settings[key].present? }
      return settings if missing.empty?

      raise DeliveryError,
        "MSG91 sms is not configured — missing #{missing.join(', ')} " \
        "under `msg91` in Rails credentials"
    end

    def post(uri, settings, body)
      request = Net::HTTP::Post.new(uri)
      request["authkey"] = settings[:auth_key]
      request["Content-Type"] = "application/json"
      request.body = body.to_json

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                 open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
        http.request(request)
      end

      return if response.is_a?(Net::HTTPSuccess)

      # Deliberately excludes the request body — it carries the plaintext code.
      raise DeliveryError, "MSG91 responded #{response.code}"
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError => e
      raise DeliveryError, "MSG91 unreachable: #{e.class}"
    end

    # MSG91 wants a bare number with country code and no plus sign.
    def digits(destination) = destination.to_s.delete("^0-9")
  end
end
