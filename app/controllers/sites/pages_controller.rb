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
      @listing = catalog.project(params[:slug])
      missing if @listing.nil?
    end

    def property
      @listing = catalog.property(params[:slug])
      missing if @listing.nil?
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
