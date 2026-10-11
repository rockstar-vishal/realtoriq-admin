# frozen_string_literal: true

module Sites
  class HostConstraint
    def self.matches?(request)
      Host.firm_host?(request.host)
    end
  end
end
