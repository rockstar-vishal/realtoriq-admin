# frozen_string_literal: true

module Sites
  # The public host is one DNS label: cp-{firm slug}.realtoriq.kgen.tech.
  # A wildcard is *.realtoriq.kgen.tech. The cp- prefix is not its own label.
  module Host
    SUFFIX = "realtoriq.kgen.tech"
    LABEL = /[a-z0-9]+(?:-[a-z0-9]+)*/
    # The listing's own code, lowercased in the path. H- for a property, P- for a project.
    CODE = /[hp]-[a-hj-np-z2-9]{6}/i
    # /projects/p-k3m9qx, /projects/p-k3m9qx/palm-court, and the older /projects/palm-court.
    LISTING_PATH = %r{\A/(projects|properties)/#{LABEL.source}(?:/#{LABEL.source})?\z}i

    module_function

    def slug_from(host)
      name = host.to_s.downcase.split(":").first
      suffixes = [ SUFFIX ]
      # A laptop name is a firm host only on a development machine. Staging
      # would otherwise serve the site for Host: cp-{slug}.localhost.
      suffixes.concat(%w[lvh.me localhost]) if Rails.env.local?
      pattern = /\Acp-(#{LABEL.source})\.(#{suffixes.map { |suffix| Regexp.escape(suffix) }.join('|')})\z/
      match = name.match(pattern)
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

    def code?(value)
      value.to_s.match?(/\A#{CODE.source}\z/i)
    end

    # Words are for a person reading the link. The code is what identifies the listing.
    def listing_path(kind, code, text)
      token = code.to_s.downcase
      return nil unless code?(token)
      return nil unless %w[projects properties].include?(kind)

      readable = text.to_s.parameterize.presence
      path = "/#{kind}/#{token}"
      readable ? "#{path}/#{readable}" : path
    end

    def public_url(firm, path = "/")
      return nil if firm.nil? || firm.slug.blank? || firm.slug.length > Inventory::PublicSlug::MAX

      "https://cp-#{firm.slug}.#{SUFFIX}#{path}"
    end
  end
end
