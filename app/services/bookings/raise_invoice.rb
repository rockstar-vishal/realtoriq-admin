# frozen_string_literal: true

module Bookings
  # Raising brokerage against a booking.
  #
  # Hard-blocked past net income: a firm cannot invoice more than it earned.
  # The refusal carries the arithmetic so the app can explain itself rather
  # than just saying no.
  class RaiseInvoice
    Result = Struct.new(:ok?, :invoice, :error_code, :error_message, :details, keyword_init: true)

    def initialize(booking:, attributes:, actor: nil)
      @booking = booking
      @attributes = attributes
      @actor = actor
    end

    def call
      return cancelled_booking if booking.cancelled?

      amount = attributes[:amount].to_i
      available = booking.invoiceable_balance

      return over_invoiced(amount, available) if amount > available

      invoice = booking.invoices.new(attributes)
      invoice.firm = booking.firm
      invoice.save!

      AuditEvent.record!(subject: invoice, firm: booking.firm, actor:,
                         action: "invoice.raised", metadata: { amount:, number: invoice.number })

      Result.new(ok?: true, invoice:)
    rescue ActiveRecord::RecordInvalid => e
      code = e.record.errors.of_kind?(:number, :taken) ? "duplicate_invoice_number" : "invalid"
      Result.new(ok?: false, invoice: e.record, error_code: code,
                 error_message: e.record.errors.full_messages.to_sentence)
    end

    private

    attr_reader :booking, :attributes, :actor

    def over_invoiced(amount, available)
      Result.new(
        ok?: false, error_code: "over_invoiced",
        error_message: "That would invoice more than this booking earned.",
        details: {
          net_income: booking.net_income,
          already_invoiced: booking.invoiced_total,
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
