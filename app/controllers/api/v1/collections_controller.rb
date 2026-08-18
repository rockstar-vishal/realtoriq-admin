# frozen_string_literal: true

module Api
  module V1
    class CollectionsController < AuthenticatedController
      before_action :require_manager
      before_action :set_booking

      def index
        render json: {
          collections: @booking.collections.recent_first.map { |c| CollectionSerializer.call(c) },
          totals: {
            invoiced: @booking.invoiced_total,
            collected: @booking.collected_total,
            outstanding: @booking.outstanding
          }
        }, status: :ok
      end

      def create
        # Optional: the design offers "Unlinked payment" as a first-class choice.
        invoice = params[:invoice_id].presence && @booking.invoices.find_by(id: params[:invoice_id])

        if params[:invoice_id].present? && invoice.nil?
          return render_error("not_found", "That invoice isn't on this booking.", status: :not_found)
        end

        result = ::Bookings::RecordCollection.new(
          booking: @booking, attributes: collection_params, invoice:,
          proof_signed_id: params[:proof_signed_id], actor: current_user
        ).call

        unless result.ok?
          return render_error(result.error_code, result.error_message,
                              status: :unprocessable_content, details: result.details)
        end

        render json: {
          collection: CollectionSerializer.call(result.collection),
          booking: BookingSerializer.detail(@booking.reload)
        }, status: :created
      end

      private

      def require_manager
        return if current_user.super_admin? || current_user.manager?

        render_error("forbidden_role", "Only a manager can work with bookings.", status: :forbidden)
      end

      def set_booking
        @booking = Booking.find_by(id: params[:booking_id])
        return if @booking

        render_error("not_found", "Booking not found", status: :not_found)
      end

      def collection_params = params.permit(:received_on, :amount, :transaction_no, :mode)
    end
  end
end
