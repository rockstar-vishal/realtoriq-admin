# frozen_string_literal: true

require "active_support/core_ext/integer/time"

# Staging: production in every respect except the handful of things below, each
# of which exists so the environment can be exercised without reaching a real
# broker or a real rupee.
#
# It is a distinct RAILS_ENV rather than production-with-a-flag on purpose. The
# fixed sign-in code is a complete authentication bypass, and the production
# guard that refuses to boot with one must stay absolute — an escape hatch that
# production could ever take is not a guard.
Rails.application.configure do
  # — everything here matches production —
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false
  config.action_controller.perform_caching = true

  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  config.active_storage.service = ENV.fetch("STORAGE_SERVICE", "local").to_sym

  config.assume_ssl = ENV.fetch("ASSUME_SSL", "true") == "true"
  config.force_ssl = ENV.fetch("FORCE_SSL", "true") == "true"

  config.log_tags = [ :request_id ]
  config.logger = ActiveSupport::TaggedLogging.logger($stdout)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  config.active_support.report_deprecations = false

  config.cache_store = :solid_cache_store
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  config.action_mailer.default_url_options = { host: ENV.fetch("APP_HOST", "localhost") }
  # Staging must not email real people. Letters are written to the log; swap to
  # :smtp only if you point it at a catch-all mailbox.
  config.action_mailer.delivery_method = ENV.fetch("MAILER_DELIVERY", "test").to_sym
  config.action_mailer.perform_caching = false
  config.action_mailer.raise_delivery_errors = false

  config.i18n.fallbacks = true
  config.active_record.dump_schema_after_migration = false
  config.active_record.attributes_for_inspect = [ :id ]

  config.hosts = ENV["ALLOWED_HOSTS"].to_s.split(",").map(&:strip).compact_blank
  config.host_authorization = { exclude: ->(request) { request.path == "/up" } }

  # — the deliberate differences —
  #
  # 1. Sign-in codes are pinned, and nothing is delivered. Anyone who knows a
  #    registered mobile can sign in as that broker, so treat the URL as
  #    sensitive: keep it off the public internet, or put it behind your own
  #    network controls. config/initializers/otp_fixed_code.rb logs a warning at
  #    boot to keep this visible.
  #
  # 2. OTP delivery defaults to :log (see config/application.rb), so MSG91 is
  #    never called and no DLT template is needed to exercise sign-in.
  #
  # 3. The OTP rate limit is loose, because a QA pass legitimately signs in
  #    dozens of times from one address.
  #
  # All three are set in config/application.rb, which reads the environment
  # rather than hardcoding — see the comments there.
end
