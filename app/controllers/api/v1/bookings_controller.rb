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

        # net_income is recomputed by a before_save, so editing the value or the
        # percentage silently moves the ceiling that over_invoiced enforces.
        # Lowering it below what has already been raised turned the documented
        # hard block into something one PATCH walked around: invoice the full
        # ₹4,50,000 of a ₹1 Cr booking, then drop agreement_value to ₹1,00,000
        # and the booking sits invoiced a hundred times past what it earned,
        # with no route that can take an invoice back.
        @booking.assign_attributes(booking_params)
        if (failure = would_strand_invoices?) then return failure end

        return render_validation_errors(@booking.errors) unless @booking.save

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

      # Runs against the *pending* figures: assign_attributes has been called but
      # nothing is saved, so recomputing here is what the save would store.
      def would_strand_invoices?
        pending = Booking.calculate_net_income(
          agreement_value: @booking.agreement_value,
          commission_percent: @booking.commission_percent,
          kicker: @booking.kicker, passback: @booking.passback
        )
        already_invoiced = @booking.invoiced_total
        # Nothing raised yet, so nothing can be stranded — whatever the new
        # figure works out to. (A booking can legitimately compute to a negative
        # net income when the passback exceeds the commission plus the kicker;
        # that is a separate question from this one.)
        return nil if already_invoiced.zero?
        return nil if pending >= already_invoiced

        render_error(
          "over_invoiced",
          "That would leave this booking invoiced past what it earns.",
          status: :unprocessable_content,
          details: {
            net_income: pending, already_invoiced:,
            shortfall: already_invoiced - pending,
            current_net_income: @booking.net_income_was
          }
        )
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
