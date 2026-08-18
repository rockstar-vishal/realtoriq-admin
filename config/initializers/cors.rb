# frozen_string_literal: true

# The React broker app is a separate origin, so the API has to opt into it
# explicitly. Origins come from config, never a wildcard — credentials are sent
# on these requests.
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins(*ENV.fetch("CORS_ORIGINS", "http://localhost:5173").split(","))

    resource "/api/*",
      headers: :any,
      methods: %i[get post patch put delete options head],
      expose: %w[ETag],
      max_age: 600
  end
end
