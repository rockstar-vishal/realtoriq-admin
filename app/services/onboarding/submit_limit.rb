# frozen_string_literal: true

module Onboarding
  # Refuses a Submit whose Content-Length is over 5 MB before Rails parses the
  # body. Loaded by hand: middleware is built before Zeitwerk.
  class SubmitLimit
    LIMIT = 5.megabytes

    def initialize(app)
      @app = app
    end

    def call(env)
      request = Rack::Request.new(env)
      length = Integer(request.get_header("CONTENT_LENGTH"), exception: false)
      if request.post? && request.path == "/self-signup" && length && length > LIMIT
        return [ 413, { "content-type" => "text/plain; charset=utf-8" }, [ "The form is too large." ] ]
      end

      @app.call(env)
    end
  end
end
