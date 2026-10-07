# frozen_string_literal: true

module Facebook
  # Operation name and Facebook's error code only. Graph exception text can
  # include the access token, so it is never written here.
  module Log
    module_function

    def info(operation, **data)
      Rails.logger.info("[facebook] #{operation}#{format(data)}")
    end

    def warn(operation, **data)
      Rails.logger.warn("[facebook] #{operation}#{format(data)}")
    end

    def error(operation, **data)
      Rails.logger.error("[facebook] #{operation}#{format(data)}")
    end

    def format(data)
      safe = data.except(:access_token, :page_access_token, :token, :result, :message)
      return "" if safe.empty?

      " " + safe.map { |key, value| "#{key}=#{value}" }.join(" ")
    end
    private_class_method :format
  end
end
