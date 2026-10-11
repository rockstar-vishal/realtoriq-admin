# frozen_string_literal: true

module Sites
  # The public host is one DNS label: cp-{firm slug}.realtoriq.kgen.tech.
  # A wildcard is *.realtoriq.kgen.tech. The cp- prefix is not its own label.
  module Host
    SUFFIX = "realtoriq.kgen.tech"
    LABEL = /[a-z0-9]+(?:-[a-z0-9]+)*/
    LISTING_PATH = %r{\A/(projects|properties)/#{LABEL.source}\z}

    module_function

    def slug_from(host)
      name = host.to_s.downcase.split(":").first
      suffixes = [ SUFFIX ]
      suffixes << "lvh.me" unless Rails.env.production?
      match = name.match(/\Acp-(#{LABEL.source})\.(#{suffixes.map { |s| Regexp.escape(s) }.join('|')})\z/)
      match && match[1]
    end

    def firm_host?(host)
      slug_from(host).present?
    end

    def allowed_path?(request)
      path = request.path
      return true if path == "/" && request.get?
      return true if path == "/enquiries" && request.post?
      request.get? && path.match?(LISTING_PATH)
    end

    def public_url(firm, path = "/")
      return nil if firm.nil? || firm.slug.blank? || firm.slug.length > Inventory::PublicSlug::MAX

      "https://cp-#{firm.slug}.#{SUFFIX}#{path}"
    end
  end

  class HostConstraint
    def self.matches?(request)
      Host.firm_host?(request.host)
    end
  end
end
