# frozen_string_literal: true

module Sites
  # Not ApplicationController: that filter refuses older phones.
  class PagesController < ActionController::Base
    layout "sites"

    before_action :load_site

    def home
      @projects = catalog.projects
      @properties = catalog.properties
    end

    def project
      present("projects")
    end

    def property
      present("properties")
    end

    private

    def load_site
      pin_storage_host
      slug = Host.slug_from(request.host)
      @firm = Firm.includes(:city, :locality).find_by(slug:) if slug.present?
      return missing unless @firm&.website_public?

      # The host already named this firm, and the site is up. Firm-owned
      # associations (a property's building) are invisible without it.
      # Nothing here reads a firm id from the request body.
      Current.firm = @firm
    end

    def present(kind)
      listing = listing_for(kind)
      return missing if listing.nil?

      canonical = listing[:path]
      unless request.path.casecmp?(canonical)
        target = request.query_string.present? ? "#{canonical}?#{request.query_string}" : canonical
        return redirect_to(target, status: :moved_permanently)
      end

      @listing = listing
    end

    # The code is the identity. A path that is only the older slug still resolves,
    # then redirects to the code. A wrong or missing title does the same.
    # An old slug can look like a code ("p-square"). A miss on the code falls
    # through to that slug. A second path segment means the code was the identity,
    # so a miss there stays a 404.
    def listing_for(kind)
      token = params[:code].to_s
      if Host.code?(token)
        found = kind == "projects" ? catalog.project_by_code(token) : catalog.property_by_code(token)
        return found if found || params[:slug].present?
      end
      return if params[:slug].present?

      kind == "projects" ? catalog.project(token.downcase) : catalog.property(token.downcase)
    end

    def catalog
      @catalog ||= Catalog.new(@firm)
    end

    # Blob URLs stay on the app host. SetCurrent would point them at this
    # firm host, and this host does not serve /rails/active_storage.
    def pin_storage_host
      options = Rails.application.routes.default_url_options
      ActiveStorage::Current.url_options = options.slice(:host, :protocol, :port).compact
    end

    def missing
      render plain: HostLock::BODY, status: :not_found, content_type: "text/html", layout: false
    end

    def enquiry_sent?
      params[:sent].to_s == "1"
    end
    helper_method :enquiry_sent?, :catalog
  end
end
