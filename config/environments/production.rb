require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Store uploaded files on the local file system (see config/storage.yml for options).
  # S3 by default — a container's disk does not survive a deploy, so :local here
  # means uploads vanish on the next release. Overridable for a deployment that
  # genuinely has persistent storage mounted.
  config.active_storage.service = ENV.fetch("STORAGE_SERVICE", "amazon").to_sym

  # Checked here rather than in an initializer: Active Storage builds the S3
  # service during boot, before config/initializers/* run, so a missing bucket
  # otherwise surfaces as `missing required option :name (ArgumentError)` out of
  # the AWS SDK — which says nothing about what to set.
  if config.active_storage.service == :amazon && ENV["AWS_BUCKET"].blank?
    raise <<~ABORT
      Refusing to boot: Active Storage is set to :amazon but AWS_BUCKET is unset.

      Set AWS_BUCKET, and AWS_REGION if the bucket is not in ap-south-1.
      Credentials are optional — omit them on EC2/ECS and the instance role is
      used, which is preferable since there is then no long-lived secret.

      To run on local disk instead, set STORAGE_SERVICE=local.
    ABORT
  end

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  config.cache_store = :solid_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # SES over SMTP. These are the SMTP credentials from the SES console, not the
  # AWS access key and not the instance role. The From address
  # (ApplicationMailer) must be a verified identity in this region.
  region = ENV.fetch("AWS_REGION", "ap-south-1")
  smtp_user_name = ENV["SMTP_USERNAME"].presence || Rails.application.credentials.dig(:smtp, :user_name)
  smtp_password = ENV["SMTP_PASSWORD"].presence || Rails.application.credentials.dig(:smtp, :password)
  if smtp_user_name.blank? || smtp_password.blank?
    raise <<~ABORT
      Refusing to boot: production mail is SES over SMTP, but the SMTP username or password is missing.

      In the SES console open SMTP settings and create SMTP credentials. Then add them
      with `bin/rails credentials:edit`:

        smtp:
          user_name: <SES SMTP username>
          password: <SES SMTP password>

      Or set SMTP_USERNAME and SMTP_PASSWORD.
    ABORT
  end

  config.action_mailer.delivery_method = :smtp
  config.action_mailer.perform_deliveries = true
  config.action_mailer.raise_delivery_errors = true
  config.action_mailer.smtp_settings = {
    address: "email-smtp.#{region}.amazonaws.com",
    port: 587,
    user_name: smtp_user_name,
    password: smtp_password,
    authentication: :plain,
    enable_starttls_auto: true
  }

  # Link host comes from APP_HOST. config/initializers/default_url_options.rb
  # applies it; without that variable, mail that builds a URL has no host.

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Enable DNS rebinding protection and other `Host` header attacks.
  # config.hosts = [
  #   "example.com",     # Allow requests from example.com
  #   /.*\.example\.com/ # Allow requests from subdomains like `www.example.com`
  # ]
  #
  # Skip DNS rebinding protection for the default health check endpoint.
  # config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
