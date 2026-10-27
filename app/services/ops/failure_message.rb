# frozen_string_literal: true

module Ops
  # Strips secrets out of a failed-job message before it is emailed.
  # Job arguments are never passed in.
  module FailureMessage
    URL = %r{https?://[^\s<>"']+}i
    SECRET = /\b(key|token|secret|password|signature)=([^\s&]+)/i
    EMAIL = /[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i
    NUMBER = /\d{10,}/
    LIMIT = 140

    module_function

    def scrub(text)
      text.to_s
        .gsub(URL, "[url]")
        .gsub(SECRET) { "#{Regexp.last_match(1)}=[hidden]" }
        .gsub(EMAIL, "[email]")
        .gsub(NUMBER, "[number]")
    end

    def excerpt(text)
      scrub(text)[0, LIMIT]
    end
  end
end
