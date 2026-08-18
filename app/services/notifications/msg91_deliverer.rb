# frozen_string_literal: true

require "net/http"

module Notifications
  # MSG91 — SMS and WhatsApp. Email goes through Action Mailer instead.
  #
  # Indian transactional SMS is DLT-regulated: the message body is registered
  # with the operator as a template and referenced by id, so this code never
  # composes it. We only supply the variable inside it.
  #
  # Credentials live in Rails credentials under `msg91`. Each transport needs
  # its own, and they're checked per-transport rather than all at once — SMS
  # should work the moment its template id lands, without waiting for WhatsApp
  # onboarding to finish.
  class Msg91Deliverer < Deliverer
    ENDPOINT = URI("https://control.msg91.com/api/v5/flow/").freeze
    WHATSAPP_ENDPOINT = URI("https://control.msg91.com/api/v5/whatsapp/whatsapp-outbound-message/bulk/").freeze
    TIMEOUT = 5

    REQUIRED_CREDENTIALS = {
      sms: %i[auth_key sms_template_id],
      whatsapp: %i[auth_key whatsapp_number whatsapp_template_name]
    }.freeze

    def deliver_code(transport:, destination:, code:, purpose:)
      case transport
      when :sms      then send_sms(destination, code)
      when :whatsapp then send_whatsapp(destination, code)
      when :email    then OtpMailer.code(destination:, code:, purpose:).deliver_later
      else raise DeliveryError, "Unknown transport #{transport}"
      end

      true
    end

    # Reports what is and isn't configured, without sending anything. Used by
    # `bin/rails msg91:check` so a misconfiguration is found before a broker
    # hits it at sign-in.
    def self.configuration_status
      settings = Rails.application.credentials.msg91 || {}

      REQUIRED_CREDENTIALS.transform_values do |keys|
        missing = keys.reject { |key| settings[key].present? }
        { ready: missing.empty?, missing: }
      end
    end

    private

    def send_sms(destination, code)
      settings = credentials_for(:sms)

      post(ENDPOINT, settings, {
        template_id: settings[:sms_template_id],
        short_url: "0",
        recipients: [ { mobiles: digits(destination), otp: code } ]
      })
    end

    def send_whatsapp(destination, code)
      settings = credentials_for(:whatsapp)

      post(WHATSAPP_ENDPOINT, settings, {
        integrated_number: settings[:whatsapp_number],
        content_type: "template",
        payload: {
          messaging_product: "whatsapp",
          type: "template",
          template: {
            name: settings[:whatsapp_template_name],
            language: { code: "en", policy: "deterministic" },
            to_and_components: [
              { to: [ digits(destination) ], components: { body_1: { type: "text", value: code } } }
            ]
          }
        }
      })
    end

    # A DeliveryError rather than a KeyError, so a missing template id surfaces
    # as "couldn't send, try again" plus a named log line — not a 500.
    def credentials_for(transport)
      settings = Rails.application.credentials.msg91 ||
        raise(DeliveryError, "MSG91 credentials are not configured")

      missing = REQUIRED_CREDENTIALS.fetch(transport).reject { |key| settings[key].present? }
      return settings if missing.empty?

      raise DeliveryError,
        "MSG91 #{transport} is not configured — missing #{missing.join(', ')} " \
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
