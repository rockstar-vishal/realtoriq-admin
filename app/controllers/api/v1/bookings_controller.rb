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
        return if invalid_list_filter?

        listed = listed_scope
        # Totals and stage counts come off the bare scope. Eager loading is
        # applied only to the page. `includes` + `sum` becomes a LEFT JOIN, so
        # a booking with an invoice and two collections would be counted three
        # times and the revenue figure would silently inflate.
        @pagy, records = pagy(
          listed.includes(
            :lead, :invoices, :collections, :typology,
            project_typology: :typology, project: :project_typologies,
            property: [ :firm, :typology, :locality ]
          ),
          limit: per_page
        )

        render json: {
          bookings: records.map { |booking| BookingSerializer.list(booking) },
          meta: pagination_meta(@pagy),
          totals: Booking.money_totals(listed),
          stage_counts: Booking.stage_counts(filtered_scope)
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
          firm: current_firm, actor: current_user, lead:,
          attributes: booking_params,
          use_existing: params[:use_existing],
          new_name: params[:new_name],
          mark_lead_booked: params[:mark_lead_booked],
          mark_property_booked: params[:mark_property_booked]
        ).call

        unless result.ok?
          if result.error_code
            return render_error(result.error_code, result.error_message,
                                status: :unprocessable_content, details: result.details)
          end

          return render_validation_errors(result.errors)
        end

        payload = { booking: BookingSerializer.detail(result.booking) }
        payload[:lead_status_unchanged] = true if result.lead_status_unchanged
        payload[:property_status_unchanged] = true if result.property_status_unchanged
        render json: payload, status: :created
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
        saved = false
        copy = nil
        stranded = nil
        link_error = nil
        property_status_unchanged = false
        begin
          Booking.transaction do
            # Same copy as create. A marketplace id must not be stored: the
            # live-unit index is per project, and two firms would then block
            # each other.
            copy = ::Bookings::Create.copy_catalog(
              project_id: params[:project_id],
              use_existing: params[:use_existing],
              new_name: params[:new_name]
            )
            raise ActiveRecord::Rollback if copy && !copy.ok?

            @booking.assign_attributes(booking_params)
            # Null clears the snapshot. Omitting the key must not: the pointer
            # may already be null because the project replaced its rows.
            @booking.clear_booked_configuration = params.key?(:project_typology_id) &&
              params[:project_typology_id].blank?
            ::Bookings::Create.apply_copy(@booking, copy, params[:project_id].presence)
            link_error = @booking.link_problem
            raise ActiveRecord::Rollback if link_error

            stranded = stranded_invoice_details
            raise ActiveRecord::Rollback if stranded

            saved = @booking.save
            raise ActiveRecord::Rollback unless saved

            property_status_unchanged = property_left_as_it_was?
          end
        rescue ActiveRecord::RecordNotUnique => e
          raise unless e.message.include?(Booking::LIVE_LISTING_INDEX)

          return render_listing_clash
        end

        if copy && !copy.ok?
          return render_error(copy.error_code, copy.error_message,
                              status: :unprocessable_content, details: copy.details)
        end
        if link_error
          return render_error(link_error[:code], link_error[:message],
                              status: :unprocessable_content, details: link_error[:details])
        end
        return render_stranded_invoices(stranded) if stranded
        return render_booking_save_failure(@booking) unless saved

        payload = { booking: BookingSerializer.detail(@booking.reload) }
        payload[:property_status_unchanged] = true if property_status_unchanged
        render json: payload, status: :ok
      end

      # Sets the booking's status and nothing else. The lead is deliberately
      # untouched, and invoices already raised stay on record.
      def cancel
        return render_error("already_cancelled", "This booking is already cancelled.",
                            status: :unprocessable_content) if @booking.cancelled?

        reason = params[:reason].to_s.strip
        return render_error("reason_required", "A cancellation needs a reason.",
                            status: :unprocessable_content) if reason.blank?

        @booking.cancel!(reason:, actor: current_user, release_property: params[:release_property])

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
        @booking = Booking.includes(
          :lead, :invoices, :collections, :created_by_user, :typology,
          project_typology: :typology, project: :project_typologies,
          property: [ :firm, :typology, :locality ]
        ).find_by(id: params[:id])
        return if @booking

        render_error("not_found", "Booking not found", status: :not_found)
      end

      def invalid_list_filter?
        if params[:stage].present? && Booking::STAGES.exclude?(params[:stage].to_s)
          render_error(
            "invalid",
            "stage must be to_invoice, awaiting_payment, paid, or cancelled.",
            status: :unprocessable_content
          )
          return true
        end

        if params[:registration].present? && %w[done pending].exclude?(params[:registration].to_s)
          render_error("invalid", "registration must be done or pending.", status: :unprocessable_content)
          return true
        end

        false
      end

      # Every filter except stage, and except the default of "live". Stage
      # counts are this set, so the pills stay put while one pill is selected.
      # `status` still narrows it: old clients send status and no stage.
      def filtered_scope
        scope = base_scope
          .search(params[:q])
          .for_phone(params[:client_phone])
          .booked_between(params[:booked_from], params[:booked_to])
          .with_registration(params[:registration])
        scope = scope.where(project_id: params[:project_id]) if params[:project_id].present?
        scope = scope.where(status: params[:status]) if params[:status].present?
        scope.recent_first
      end

      def listed_scope
        scope = filtered_scope
        return scope.in_stage(params[:stage]) if params[:stage].present?
        return scope if params[:status].present?

        scope.live
      end

      # Runs against the *pending* figures: assign_attributes has been called but
      # nothing is saved, so recomputing here is what the save would store.
      def stranded_invoice_details
        pending = Booking.calculate_net_income(
          agreement_value: @booking.agreement_value,
          commission_percent: @booking.commission_percent,
          kicker: @booking.kicker, passback: @booking.passback
        )
        already_invoiced = @booking.live_invoiced_sum
        # Nothing raised yet, so nothing can be stranded — whatever the new
        # figure works out to. (A booking can legitimately compute to a negative
        # net income when the passback exceeds the commission plus the kicker;
        # that is a separate question from this one.)
        return nil if already_invoiced.zero?
        return nil if pending >= already_invoiced

        {
          net_income: pending, already_invoiced:,
          shortfall: already_invoiced - pending,
          current_net_income: @booking.net_income_was
        }
      end

      def render_stranded_invoices(details)
        render_error(
          "over_invoiced",
          "That would leave this booking invoiced past what it earns.",
          status: :unprocessable_content,
          details:
        )
      end

      def render_validation_errors(errors)
        render_error("invalid", errors.full_messages.to_sentence,
                     status: :unprocessable_content, details: errors.to_hash)
      end

      # The flag was sent, and this save did not move an own Available listing
      # the booking had just been pointed at.
      def property_left_as_it_was?
        return false unless ActiveModel::Type::Boolean.new.cast(params[:mark_property_booked])
        return true unless @booking.saved_change_to_property_id? && @booking.property_id.present?

        !::Bookings::ListingStatus.mark_booked!(@booking, current_user)
      end

      def render_listing_clash
        other = @booking.conflicting_live_listing
        render_error(
          "listing_already_booked",
          "This listing already has a live booking.",
          status: :unprocessable_content,
          details: { booking_id: other&.id, code: other&.code }
        )
      end

      def render_booking_save_failure(booking)
        if booking.errors.of_kind?(:unit_no, :taken)
          return render_error(
            "unit_taken",
            "That unit is already booked on this project.",
            status: :unprocessable_content,
            details: { project_id: booking.project_id, unit_no: booking.unit_no }
          )
        end

        render_validation_errors(booking.errors)
      end

      def per_page
        requested = params[:per_page].to_i
        return 25 if requested <= 0

        requested.clamp(1, 50)
      end

      def booking_params
        params.permit(:project_id, :property_id, :project_typology_id, :builder_ref_no, :unit_no, :carpet_area_sqft,
                      :customer_name, :customer_mobile, :booked_on, :agreement_value,
                      :commission_percent, :kicker, :passback, :other_details,
                      :registration_done_on, :client_paid_percent)
      end
    end
  end
end
