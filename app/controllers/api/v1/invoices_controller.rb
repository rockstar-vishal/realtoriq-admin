# frozen_string_literal: true

module Api
  module V1
    class InvoicesController < AuthenticatedController
      before_action :require_manager
      before_action :set_booking

      def index
        render json: {
          invoices: @booking.invoices.recent_first.map { |i| InvoiceSerializer.call(i) },
          totals: {
            net_income: @booking.net_income,
            invoiced: @booking.invoiced_total,
            invoiceable_balance: @booking.invoiceable_balance
          }
        }, status: :ok
      end

      def create
        result = ::Bookings::RaiseInvoice.new(
          booking: @booking, attributes: invoice_params, actor: current_user
        ).call

        unless result.ok?
          return render_error(result.error_code, result.error_message,
                              status: :unprocessable_content, details: result.details)
        end

        render json: {
          invoice: InvoiceSerializer.call(result.invoice),
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

      def invoice_params = params.permit(:number, :issued_on, :amount, :comment)
    end
  end
end
