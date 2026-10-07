# frozen_string_literal: true

# The only place the Graph version lives. This file runs before Zeitwerk loads
# the app, so it must not reference an autoloaded constant.
require "koala"

Koala.config.api_version = "v26.0"

# A slow Graph call must not hold a Puma thread. Timeouts raise Faraday::Error.
Koala.http_service.http_options = { request: { timeout: 15, open_timeout: 15 } }
