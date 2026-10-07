# frozen_string_literal: true

# Production errors only. The DSN is not in the repo: set SENTRY_DSN on the
# host, or production.sentry.dsn in credentials. Deploying this file does not
# start reporting until one of those is present. Staging and development send
# nothing.
#
# send_default_pii stays off. On sentry-rails 7.1 that keeps request bodies,
# query strings and cookies out of events — OTP codes, JWTs, and Facebook
# tokens that Koala puts on Graph URLs. The breadcrumb loggers still attach
# SQL text and presigned Active Storage URLs; those two fields are removed
# below, because the next exception ships the last breadcrumbs with it.
Sentry.init do |config|
  config.dsn = ENV["SENTRY_DSN"].presence ||
    Rails.application.credentials.dig(:production, :sentry, :dsn)
  config.enabled_environments = %w[production]
  config.breadcrumbs_logger = [ :active_support_logger, :http_logger ]
  config.send_default_pii = false
  config.before_breadcrumb = lambda do |breadcrumb, _hint|
    data = breadcrumb.data
    if data.is_a?(Hash)
      data.delete(:sql) if breadcrumb.category == "sql.active_record"
      data.delete(:url) if breadcrumb.category == "service_url.active_storage"
    end
    breadcrumb
  end
end
