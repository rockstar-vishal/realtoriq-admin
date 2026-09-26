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
end
