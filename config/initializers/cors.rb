# frozen_string_literal: true

# The React broker app is a separate origin, so the API has to opt into it.
#
# Staging answers **any** origin by default. A React build running on a laptop,
# a Vercel preview URL or a teammate's machine can then talk to it without
# someone redeploying the box to add an origin to a list — which is the whole
# point of having a staging box. Development and production still take an
# explicit list.
#
# What makes the wildcard safe here rather than merely convenient: this API is
# `ActionController::API` with no cookie session, and `AuthenticatedController`
# will only accept a verified JWT from the Authorization header. Nothing is
# carried ambiently by the browser, so a hostile page that reaches the API still
# has no token and gets a 401. `credentials` stays off (rack-cors 3 defaults it
# to false, and it refuses to combine `true` with `*` at all), which also keeps
# the wildcard away from the admin panel's cookie session — that lives outside
# the `/api/*` resource below in any case.
DEFAULT_CORS_ORIGINS = "http://localhost:5173"

cors_origins = ENV["CORS_ORIGINS"].to_s.split(",").map(&:strip).compact_blank
cors_origins = [ Rails.env.staging? ? "*" : DEFAULT_CORS_ORIGINS ] if cors_origins.empty?

# Loud rather than fatal. A wildcard in production is a real weakening and
# someone should have to justify it, but — unlike the fixed sign-in code, which
# is a complete authentication bypass and so refuses to boot — it grants a
# hostile origin nothing it could not already do with curl. Refusing to boot
# would be out of proportion to that.
if cors_origins.include?("*") && Rails.env.production?
  Rails.logger.warn(
    "[cors] CORS_ORIGINS is a wildcard in production. Any site can call /api/* " \
    "from a visitor's browser. Requests still need a Bearer token, but set an " \
    "explicit origin list unless you meant this."
  )
end

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins(*cors_origins)

    # Scoped to the API. The admin panel is server-rendered on a cookie session
    # and must never be reachable cross-origin.
    resource "/api/*",
      headers: :any,
      methods: %i[get post patch put delete options head],
      expose: %w[ETag],
      max_age: 600
  end
end
