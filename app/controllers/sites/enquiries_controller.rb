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
          listing_code: return_code
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
        @listing = catalog.project_by_code(return_code)
        return missing if @listing.nil?

        render "sites/pages/project", status: :unprocessable_content
      when "property"
        @listing = catalog.property_by_code(return_code)
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
      listing = case return_kind
      when "project" then catalog.project_by_code(return_code)
      when "property" then catalog.property_by_code(return_code)
      end
      listing ? listing[:path] : "/"
    end

    def return_kind
      params[:listing_kind].to_s
    end

    def return_code
      code = params[:listing_code].to_s
      code if Host.code?(code)
    end
  end
end
