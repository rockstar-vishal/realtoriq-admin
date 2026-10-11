# frozen_string_literal: true

module Sites
  # The microsite shares a process with the API and the admin panel. On a
  # firm host, every other path is a 404 — including /admin and /api/v1.
  class HostLock
    BODY = "Not found"

    def initialize(app)
      @app = app
    end

    def call(env)
      request = ActionDispatch::Request.new(env)
      return @app.call(env) unless Host.firm_host?(request.host)
      return not_found unless Host.allowed_path?(request)

      @app.call(env)
    end

    private

    def not_found
      [ 404, { "content-type" => "text/html; charset=utf-8", "x-robots-tag" => "noindex" }, [ BODY ] ]
    end
  end
end
