# frozen_string_literal: true

module Sites
  class EnquiriesController < PagesController
    def create
      return redirect_to(sent_path) if params[:company].present?
      return too_many unless Throttle.allow?(ip: request.remote_ip, firm_id: @firm.id, request:)
      unless Recaptcha.accepted?(captcha_token, remote_ip: request.remote_ip, hostname: request.host)
        @enquiry_error = "Confirm you are not a robot."
        return render_form
      end

      result = dispatch_form
      return redirect_to(sent_path) if result.ok?

      @enquiry_error = result.error
      render_form
    end

    private

    # Google's checkbox posts g-recaptcha-response. A field we named ourselves
    # never arrives.
    def captcha_token
      params[:"g-recaptcha-response"]
    end

    def dispatch_form
      case return_kind
      when ""
        ReceiveContact.call(firm: @firm, name: params[:name], mobile: params[:mobile], message: params[:message])
      when "project", "property"
        ReceiveEnquiry.call(
          firm: @firm,
          name: params[:name],
          mobile: params[:mobile],
          message: params[:message],
          listing_kind: return_kind,
          listing_slug: return_slug
        )
      else
        ReceiveEnquiry::Result.new(ok?: false, error: "Could not send that just now.")
      end
    end

    def too_many
      render plain: "Too many enquiries. Try again shortly.", status: :too_many_requests, content_type: "text/html"
    end

    def render_form
      case return_kind
      when "project"
        @listing = catalog.project(return_slug)
        return missing if @listing.nil?

        render "sites/pages/project", status: :unprocessable_content
      when "property"
        @listing = catalog.property(return_slug)
        return missing if @listing.nil?

        render "sites/pages/property", status: :unprocessable_content
      else
        @projects = catalog.projects
        @properties = catalog.properties
        render "sites/pages/home", status: :unprocessable_content
      end
    end

    def sent_path
      path = safe_return_path
      "#{path}#{path.include?('?') ? '&' : '?'}sent=1"
    end

    def safe_return_path
      kind, slug = return_kind, return_slug
      return "/projects/#{slug}" if kind == "project" && slug.present?
      return "/properties/#{slug}" if kind == "property" && slug.present?

      "/"
    end

    def return_kind
      params[:listing_kind].to_s
    end

    def return_slug
      slug = params[:listing_slug].to_s
      slug if slug.match?(Inventory::PublicSlug::FORMAT)
    end
  end
end
