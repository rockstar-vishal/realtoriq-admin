# frozen_string_literal: true

module Admin
  class FirmsController < BaseController
    before_action :set_firm, only: %i[show edit update activate suspend]

    def index
      scope = Firm.search(params[:q])
      scope = scope.where(status: params[:status]) if params[:status].present?
      scope = filter_by_verification(scope)

      @pagy, @firms = pagy(scope.includes(:contact_channels).order(created_at: :desc))
      @status_counts = Firm.group(:status).count
    end

    def show
      @tab = params[:tab].presence_in(%w[overview verification users subscription]) || "overview"
      @channels = @firm.contact_channels.ordered
      @users = @firm.users.active_first
    end

    def new
      @form = FirmForm.new
    end

    def create
      @form = FirmForm.new(Firm.new, firm_params)

      if @form.save
        AuditEvent.record!(subject: @form.firm, action: "firm.created")
        redirect_to admin_firm_path(@form.firm), notice: "#{@form.firm.name} created."
      else
        render :new, status: :unprocessable_content
      end
    end

    def edit
      @form = FirmForm.new(@firm)
    end

    def update
      @form = FirmForm.new(@firm, firm_params)

      if @form.save
        AuditEvent.record!(subject: @firm, action: "firm.updated")
        redirect_to admin_firm_path(@firm), notice: "Changes saved."
      else
        render :edit, status: :unprocessable_content
      end
    end

    def activate
      @firm.activate!(actor: current_admin)
      redirect_to admin_firm_path(@firm), notice: "#{@firm.name} is active."
    end

    def suspend
      reason = params.dig(:firm, :suspension_reason).to_s.strip

      if reason.blank?
        redirect_to admin_firm_path(@firm), alert: "A suspension needs a reason."
        return
      end

      @firm.suspend!(reason:, actor: current_admin)
      redirect_to admin_firm_path(@firm), notice: "#{@firm.name} suspended."
    end

    private

    def set_firm
      @firm = Firm.find_by!(slug: params[:slug])
    end

    def filter_by_verification(scope)
      fully_verified = ContactChannel.verification_verified
                                     .group(:firm_id)
                                     .having("COUNT(*) = ?", ContactChannel::KINDS.size)
                                     .select(:firm_id)

      case params[:verification]
      when "complete" then scope.where(id: fully_verified)
      when "incomplete" then scope.where.not(id: fully_verified)
      else scope
      end
    end

    def firm_params
      params.expect(
        firm: [
          *FirmForm::FIRM_FIELDS,
          *FirmForm::CONTACT_FIELDS,
          *FirmForm::OWNER_FIELDS,
          *FirmForm::SUBSCRIPTION_FIELDS,
          :logo
        ]
      )
    end
  end
end
