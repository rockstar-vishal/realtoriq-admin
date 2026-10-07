# frozen_string_literal: true

require "net/http"

module Notifications
  # Twilio Content API for WhatsApp. SMS stays on MSG91.
  #
  # The approved template is `realtoriq_otp` (ContentSid HX…). Twilio numbers
  # placeholders {{1}}, {{2}}, so the code goes in variable "1". The app never
  # composes the message body.
  class TwilioDeliverer < Deliverer
    TIMEOUT = 5
    CODE_VARIABLE = "1"
    ACCOUNT_SID_FORMAT = /\AAC[0-9a-f]{32}\z/i

    REQUIRED_CREDENTIALS = %i[account_sid auth_token whatsapp_from content_sid].freeze

    def deliver_code(transport:, destination:, code:, purpose:)
      raise DeliveryError, "Unknown transport #{transport}" unless transport == :whatsapp
      raise DeliveryError, "A code needs a purpose" if purpose.blank?

      send_whatsapp(destination, code)
      true
    end

    def self.configuration_status
      settings = Rails.application.credentials.twilio || {}
      missing = REQUIRED_CREDENTIALS.reject { |key| settings[key].present? }

      { whatsapp: { ready: missing.empty?, missing: } }
    end

    private

    def send_whatsapp(destination, code)
      settings = credentials

      post(endpoint(settings[:account_sid]), settings, {
        "From" => whatsapp_address(settings[:whatsapp_from]),
        "To" => whatsapp_address(destination),
        "ContentSid" => settings[:content_sid],
        "ContentVariables" => { CODE_VARIABLE => code }.to_json
      })
    end

    def credentials
      settings = Rails.application.credentials.twilio ||
        raise(DeliveryError, "Twilio credentials are not configured")

      missing = REQUIRED_CREDENTIALS.reject { |key| settings[key].present? }
      return settings if missing.empty?

      raise DeliveryError,
        "Twilio whatsapp is not configured — missing #{missing.join(', ')} " \
        "under `twilio` in Rails credentials"
    end

    def endpoint(account_sid)
      unless account_sid.to_s.match?(ACCOUNT_SID_FORMAT)
        raise DeliveryError, "Twilio account_sid is not a valid Account SID"
      end

      URI("https://api.twilio.com/2010-04-01/Accounts/#{account_sid}/Messages.json")
    end

    def post(uri, settings, form)
      request = Net::HTTP::Post.new(uri)
      request.basic_auth(settings[:account_sid], settings[:auth_token])
      request.set_form_data(form)

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                 open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
        http.request(request)
      end

      return if response.is_a?(Net::HTTPSuccess)

      # The response body can echo the template text, which includes the code.
      raise DeliveryError, "Twilio responded #{response.code}"
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError => e
      raise DeliveryError, "Twilio unreachable: #{e.class}"
    end

    # Twilio wants the whatsapp: prefix and an E.164 number.
    def whatsapp_address(number)
      "whatsapp:+#{number.to_s.delete('^0-9')}"
    end
  end
end
