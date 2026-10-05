# frozen_string_literal: true

namespace :msg91 do
  desc "Report which OTP transports are configured (sends nothing)"
  task check: :environment do
    sms = Notifications::Msg91Deliverer.configuration_status.fetch(:sms)
    whatsapp = Notifications::TwilioDeliverer.configuration_status.fetch(:whatsapp)
    msg91 = Rails.application.credentials.msg91 || {}
    twilio = Rails.application.credentials.twilio || {}

    line = lambda do |name, result|
      if result[:ready]
        puts "  #{name}: ready"
      else
        puts "  #{name}: not ready — missing #{result[:missing].join(", ")}"
      end
    end
    tail = lambda do |value|
      value.present? ? "set (…#{value.to_s.last(4)})" : "MISSING"
    end

    puts "OTP delivery is set to: #{Rails.configuration.x.otp_delivery}"
    puts "SMS goes through MSG91. WhatsApp goes through Twilio. Email goes through Action Mailer."
    puts
    puts "SMS (MSG91)"
    puts "  auth_key: #{tail.call(msg91[:auth_key])}"
    puts "  sms_template_id: #{msg91[:sms_template_id].presence || "MISSING"}"
    puts "  sms_sender_id: #{msg91[:sms_sender_id].presence || "MISSING"}"
    puts "  dlt_entity_id: #{msg91[:dlt_entity_id].present? ? "set" : "MISSING (mapped on the MSG91 panel, not sent)"}"
    line.call("sms", sms)
    puts
    puts "WhatsApp (Twilio)"
    puts "  account_sid: #{tail.call(twilio[:account_sid])}"
    puts "  auth_token: #{tail.call(twilio[:auth_token])}"
    puts "  whatsapp_from: #{twilio[:whatsapp_from].presence || "MISSING"}"
    puts "  content_sid: #{twilio[:content_sid].presence || "MISSING"}"
    puts "  content_template_name: #{twilio[:content_template_name].presence || "not set"}"
    line.call("whatsapp", whatsapp)
    puts
    puts "  email: ready (Action Mailer)"

    next if sms[:ready] && whatsapp[:ready]

    puts <<~NEXT

      Add the missing values with `bin/rails credentials:edit`:

        msg91:
          auth_key: <your key>
          sms_template_id: <MSG91 flow template id>
          sms_sender_id: <DLT sender id>
          dlt_entity_id: <DLT entity id, for the record>

        twilio:
          account_sid: <AC…>
          auth_token: <auth token>
          whatsapp_from: <+E.164 WhatsApp sender>
          content_sid: <HX…>
          content_template_name: <approved template name>

      Until then those transports raise a delivery error and the API returns
      `delivery_failed` rather than pretending a code was sent.
    NEXT
  end
end
