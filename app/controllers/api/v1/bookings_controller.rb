# frozen_string_literal: true

module Api
  module V1
    # Bookings are commission records, so the whole controller is restricted to
    # managers and the super admin — an agent gets forbidden_role on every
    # action, including ones about a lead of their own.
    class BookingsController < AuthenticatedController
      before_action :require_manager
      before_action :set_booking, only: %i[show update cancel]

      def index
        scope = filtered_scope
        # Totals come off the bare scope, and the eager loading is applied only
        # to the page being rendered. `includes` + `sum` becomes a LEFT JOIN, so
        # a booking with an invoice and two collections would be counted three
        # times and the revenue figure would silently inflate.
        @pagy, records = pagy(scope.includes(:lead, :project, :invoices, :collections),
                              limit: per_page)

        render json: {
          bookings: records.map { |b| BookingSerializer.list(b) },
          meta: pagination_meta(@pagy),
          # The list header in the design shows firm totals alongside the count.
          totals: totals_for(scope)
        }, status: :ok
      end

      def show
        render json: { booking: BookingSerializer.detail(@booking) }, status: :ok
      end

      def create
        lead = Lead.find_by(id: params[:lead_id])
        # Every booking carries a lead reference — the design's flow finds one
        # by phone before the form opens.
        return render_error("lead_required", "A booking needs a lead.", status: :unprocessable_content) if lead.nil?

        result = ::Bookings::Create.new(
          firm: current_firm, actor: current_user, lead:, attributes: booking_params
        ).call

        return render_validation_errors(result.errors) unless result.ok?

        render json: { booking: BookingSerializer.detail(result.booking) }, status: :created
      end

      def update
        return render_error("already_cancelled", "This booking is cancelled.",
                            status: :unprocessable_content) if @booking.cancelled?

        return render_validation_errors(@booking.errors) unless @booking.update(booking_params)

        render json: { booking: BookingSerializer.detail(@booking.reload) }, status: :ok
      end

      # Sets the booking's status and nothing else. The lead is deliberately
      # untouched, and invoices already raised stay on record.
      def cancel
        return render_error("already_cancelled", "This booking is already cancelled.",
                            status: :unprocessable_content) if @booking.cancelled?

        reason = params[:reason].to_s.strip
        return render_error("reason_required", "A cancellation needs a reason.",
                            status: :unprocessable_content) if reason.blank?

        @booking.cancel!(reason:, actor: current_user)

        render json: { booking: BookingSerializer.detail(@booking.reload) }, status: :ok
      end

      private

      def require_manager
        return if current_user.super_admin? || current_user.manager?

        render_error("forbidden_role", "Only a manager can work with bookings.", status: :forbidden)
      end

      # Deliberately without `includes` — see index. Callers that render a
      # single record add their own eager loading.
      def base_scope = Booking.all

      def set_booking
        @booking = Booking.includes(:lead, :project, :invoices, :collections)
                          .find_by(id: params[:id])
        return if @booking

        render_error("not_found", "Booking not found", status: :not_found)
      end

      def filtered_scope
        scope = base_scope
          .search(params[:q])
          .for_phone(params[:client_phone])
          .booked_between(params[:booked_from], params[:booked_to])

        scope = scope.where(project_id: params[:project_id]) if params[:project_id].present?
        scope = params[:status].present? ? scope.where(status: params[:status]) : scope.live

        scope.recent_first
      end

      def totals_for(scope)
        # Re-selects by id so no join from the caller can duplicate rows.
        live = Booking.where(id: scope.select(:id)).live

        {
          agreement_value: live.sum(:agreement_value),
          net_income: live.sum(:net_income)
        }
      end

      def render_validation_errors(errors)
        render_error("invalid", errors.full_messages.to_sentence,
                     status: :unprocessable_content, details: errors.to_hash)
      end

      def per_page
        requested = params[:per_page].to_i
        return 25 if requested <= 0

        requested.clamp(1, 50)
      end

      def booking_params
        params.permit(:project_id, :builder_ref_no, :unit_no, :carpet_area_sqft,
                      :customer_name, :customer_mobile, :booked_on, :agreement_value,
                      :commission_percent, :kicker, :passback, :other_details,
                      :registration_done_on, :client_paid_percent)
      end
    end
  end
end
