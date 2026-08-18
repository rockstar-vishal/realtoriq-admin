# frozen_string_literal: true

module Bookings
  # Money received. Blocked two ways: the booking's total collected cannot pass
  # what has been invoiced, and a payment filed against a specific invoice
  # cannot take that invoice past its own amount — which is what catches a
  # payment recorded against the wrong invoice.
  class RecordCollection
    Result = Struct.new(:ok?, :collection, :error_code, :error_message, :details, keyword_init: true)

    def initialize(booking:, attributes:, invoice: nil, proof_signed_id: nil, actor: nil)
      @booking = booking
      @attributes = attributes
      @invoice = invoice
      @proof_signed_id = proof_signed_id
      @actor = actor
    end

    def call
      return cancelled_booking if booking.cancelled?

      amount = attributes[:amount].to_i

      if (failure = over_total?(amount)) then return failure end
      if (failure = over_invoice?(amount)) then return failure end

      collection = booking.collections.new(attributes)
      collection.firm = booking.firm
      collection.invoice = invoice
      collection.proof.attach(proof_signed_id) if proof_signed_id.present?
      collection.save!

      AuditEvent.record!(subject: collection, firm: booking.firm, actor:,
                         action: "collection.recorded", metadata: { amount: })

      Result.new(ok?: true, collection:)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok?: false, collection: e.record, error_code: "invalid",
                 error_message: e.record.errors.full_messages.to_sentence)
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      Result.new(ok?: false, error_code: "invalid_upload",
                 error_message: "That attachment isn't a valid upload.")
    end

    private

    attr_reader :booking, :attributes, :invoice, :proof_signed_id, :actor

    def over_total?(amount)
      available = booking.invoiced_total - booking.collected_total
      return nil if amount <= available

      Result.new(
        ok?: false, error_code: "over_collected",
        error_message: "That would collect more than has been invoiced.",
        details: {
          invoiced: booking.invoiced_total,
          already_collected: booking.collected_total,
          attempted: amount,
          available: [ available, 0 ].max
        }
      )
    end

    def over_invoice?(amount)
      return nil if invoice.blank?

      available = invoice.collectable_balance
      return nil if amount <= available

      Result.new(
        ok?: false, error_code: "over_collected_for_invoice",
        error_message: "That would collect more than invoice #{invoice.number} is for.",
        details: {
          invoice_number: invoice.number,
          invoice_amount: invoice.amount,
          already_collected: invoice.collected_total,
          attempted: amount,
          available: [ available, 0 ].max
        }
      )
    end

    def cancelled_booking
      Result.new(ok?: false, error_code: "already_cancelled",
                 error_message: "This booking is cancelled.")
    end
  end
end
