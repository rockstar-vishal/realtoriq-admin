require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_mailbox/engine"
require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module KgenRealtoriqAdmin
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.0

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # An India-only product. Timestamps are still stored in UTC; this only
    # affects how they're rendered and how Date.current resolves.
    config.time_zone = "Asia/Kolkata"

    # Every table uses UUID primary keys — see lib/uuid_v7.rb for why.
    config.generators do |g|
      g.orm :active_record, primary_key_type: :uuid
      g.system_tests = nil
    end

    # How one-time codes are delivered. Anywhere but production defaults to
    # logging the code, so the auth flow is exercisable without an MSG91
    # account; LogDeliverer refuses to run in production regardless.
    config.x.otp_delivery = ENV.fetch("OTP_DELIVERY") { Rails.env.production? ? "msg91" : "log" }

    # A fixed sign-in code, so testing doesn't mean reading a log for six digits.
    #
    # This is a complete authentication bypass: anyone who knows a registered
    # mobile number can sign in as that broker. It is therefore development-only
    # by default, and config/initializers/otp_fixed_code.rb refuses to let the
    # application boot in production with it set — a warning would eventually be
    # ignored, a failed boot cannot be.
    #
    # Test deliberately keeps random codes so the specs exercise the real
    # generation, expiry and attempt-counting logic.
    config.x.otp_fixed_code =
      ENV["OTP_FIXED_CODE"].presence || ("888888" if Rails.env.development?)

    # Sign-in code requests allowed per IP per 5 minutes. Tight in production,
    # where /auth/otp is the app's only unauthenticated write. Loose elsewhere,
    # because one developer machine driving the whole test suite — or a Postman
    # collection run — legitimately makes a dozen requests in a minute.
    config.x.otp_rate_limit = Rails.env.production? ? 12 : 100
  end
end
