# frozen_string_literal: true

module Admin
  class ApplicationsController < BaseController
    before_action :set_application, only: %i[show edit update reject file]
    before_action :require_open, only: %i[edit update]

    def index
      @tab = params[:tab].presence_in(%w[awaiting activated rejected lapsed]) || "awaiting"
      scope = OnboardingApplication.across_firms.matching(params[:q])
      scope = case @tab
      when "activated" then scope.activated
      when "rejected" then scope.queue_rejected
      when "lapsed" then scope.queue_lapsed
      else scope.awaiting
      end
      @pagy, @applications = pagy(scope.includes(:city).order(submitted_at: :desc))
    end

    def show
      @duplicates = @application.duplicates
    end

    def edit
      @cities = City.active.alphabetical
      @localities = Locality.active.includes(:city).where(city_id: @application.city_id).alphabetical
    end

    def update
      if Onboarding::UpdateDetails.new(@application, application_params).save
        redirect_to admin_application_path(@application), notice: "Changes saved."
      else
        @cities = City.active.alphabetical
        @localities = Locality.active.includes(:city).alphabetical
        render :edit, status: :unprocessable_content
      end
    end

    def reject
      reason = params[:reason].to_s
      if reason.strip.blank?
        redirect_to admin_application_path(@application), alert: "A rejection needs a reason."
        return
      end

      if Onboarding::Reject.call(application: @application, admin: current_admin, reason:)
        redirect_to admin_application_path(@application), notice: "Application rejected."
      else
        redirect_to admin_application_path(@application), alert: "This application can no longer be rejected."
      end
    end

    def file
      attachment = file_attachment
      return head :not_found unless attachment&.attached?

      type = attachment.blob.content_type.to_s
      type = "application/octet-stream" unless type.in?(Onboarding::FILE_TYPES)
      send_data attachment.download,
        filename: attachment.filename.to_s.gsub(/[^\w.\-]+/, "_"),
        type:,
        disposition: "inline"
      response.headers["Cache-Control"] = "no-store"
    end

    private

    def set_application
      @application = OnboardingApplication.across_firms.find_by!(reference: params[:reference])
    end

    def require_open
      return if @application.submitted? && !@application.firm.discarded?

      redirect_to admin_application_path(@application), alert: "This application can no longer be edited."
    end

    def application_params
      params.require(:onboarding_application).permit(
        :applicant_name, :applicant_designation, :entity_type, :firm_name, :legal_name,
        :address_line1, :address_line2, :city_id, :locality_id, :pincode, :pan, :gst_number,
        :team_size, :rera_registered, :rera_number, :rera_valid_till, :internal_notes,
        extra_locality_ids: []
      )
    end

    def file_attachment
      case params[:slot]
      when "visiting_card" then @application.visiting_card
      when "rera_certificate" then @application.rera_certificate
      when "acceptance_pdf" then @application.legal_acceptance&.document
      end
    end
  end
end
