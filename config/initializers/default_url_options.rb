# frozen_string_literal: true

# Active Storage builds absolute URLs, and serializers build them outside the
# controller — where ActiveStorage::Current isn't populated. Without a default
# host every photo URL raises "Missing host to link to!".
#
# Per-request options still win: Api::V1::BaseController includes
# ActiveStorage::SetCurrent, so a request served on another host gets that host.
# This is only the floor.
host = ENV.fetch("APP_HOST") { Rails.env.production? ? nil : "http://localhost:3000" }

if host.present?
  uri = URI.parse(host)

  options = { host: uri.host, protocol: uri.scheme }
  options[:port] = uri.port unless uri.port == uri.default_port

  Rails.application.routes.default_url_options.merge!(options)
  Rails.application.config.action_mailer.default_url_options = options
elsif Rails.env.production?
  Rails.logger.warn(
    "[storage] APP_HOST is unset — file URLs will fail. Set it to the app's public origin."
  )
end
