# frozen_string_literal: true

namespace :notifications do
  desc "Print a new VAPID keypair for credentials (do not commit the private key)"
  task generate_vapid: :environment do
    key = WebPush.generate_key
    puts "Paste into Rails credentials under vapid. Do not commit the private key."
    puts "public_key: #{key.public_key}"
    puts "private_key: #{key.private_key}"
    puts "subject: mailto:you@example.com"
  end

  desc "Send one SMS, one WhatsApp and one email. Production only. PHONE= EMAIL= CONFIRM=1"
  task probe: :environment do
    abort("notifications:probe only runs in production.") unless Rails.env.production?

    phone = ENV["PHONE"].to_s
    email = ENV["EMAIL"].to_s.strip
    digits = phone.delete("^0-9")
    digits = "91#{digits}" if digits.length == 10
    abort("Set PHONE to the mobile that should receive the SMS and WhatsApp.") unless digits.match?(/\A91\d{10}\z/)
    abort("Set EMAIL to the address that should receive the email.") unless email.match?(/\A[^@\s]+@[^@\s]+\z/)
    abort("Set CONFIRM=1 to send the three messages.") unless ENV["CONFIRM"] == "1"

    destination = "+#{digits}"
    code = SecureRandom.random_number(10**6).to_s.rjust(6, "0")
    puts "Probe code #{code}"
    puts "SMS and WhatsApp: #{destination}"
    puts "Email: #{email}"

    report = lambda do |name, &block|
      block.call
      puts "#{name}: sent"
    rescue StandardError => e
      puts "#{name}: failed (#{e.class}: #{e.message})"
    end

    report.call("sms") do
      Notifications::Msg91Deliverer.new.deliver_code(
        transport: :sms, destination:, code:, purpose: "login"
      )
    end
    report.call("whatsapp") do
      Notifications::TwilioDeliverer.new.deliver_code(
        transport: :whatsapp, destination:, code:, purpose: "verify_whatsapp"
      )
    end
    report.call("email") do
      OtpMailer.code(destination: email, code:, purpose: "verify_email").deliver_now
    end
  end
end
