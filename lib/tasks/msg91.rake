# frozen_string_literal: true

namespace :msg91 do
  desc "Report which MSG91 transports are configured (sends nothing)"
  task check: :environment do
    status = Notifications::Msg91Deliverer.configuration_status
    settings = Rails.application.credentials.msg91 || {}

    puts "OTP delivery is set to: #{Rails.configuration.x.otp_delivery}"
    puts "auth_key: #{settings[:auth_key].present? ? "set (…#{settings[:auth_key].to_s.last(4)})" : 'MISSING'}"
    puts

    status.each do |transport, result|
      if result[:ready]
        puts "  #{transport}: ready"
      else
        puts "  #{transport}: not ready — missing #{result[:missing].join(', ')}"
      end
    end

    puts "  email: ready (Action Mailer, not MSG91)"

    return if status.values.all? { |r| r[:ready] }

    puts <<~NEXT

      Add the missing values with `bin/rails credentials:edit`:

        msg91:
          auth_key: <your key>
          sms_template_id: <DLT-approved flow template id>
          whatsapp_number: <WhatsApp Business number>
          whatsapp_template_name: <approved template name>

      Until then those transports raise a delivery error and the API returns
      `delivery_failed` rather than pretending a code was sent.
    NEXT
  end
end
