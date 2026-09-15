# frozen_string_literal: true

module Api
  module V1
    class BookingDocumentsController < AuthenticatedController
      before_action :require_manager
      before_action :set_booking

      def create
        document = @booking.booking_documents.new(
          firm: current_firm, slot: params[:slot], label: params[:label],
          uploaded_by_user: current_user
        )
        accepted = Uploads::AcceptSignedId.new(
          signed_id: params.require(:signed_id), firm: current_firm, purpose: "booking_document"
        ).call
        unless accepted.ok?
          return render_error(accepted.error_code, accepted.error_message, status: :unprocessable_content)
        end

        document.file.attach(accepted.blob)

        unless document.save
          return render_error("invalid", document.errors.full_messages.to_sentence,
                              status: :unprocessable_content, details: document.errors.to_hash)
        end

        render json: { booking: BookingSerializer.detail(@booking.reload) }, status: :created
      rescue ActiveRecord::RecordNotUnique
        # One file per named slot; only "Others" repeats.
        render_error("slot_taken", "That slot already has a document. Remove it first.",
                     status: :unprocessable_content)
      end

      def destroy
        document = @booking.booking_documents.find_by(id: params[:id])
        return render_error("not_found", "Document not found", status: :not_found) if document.nil?

        document.destroy
        render json: { booking: BookingSerializer.detail(@booking.reload) }, status: :ok
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
    end
  end
end
