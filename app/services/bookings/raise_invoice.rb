# frozen_string_literal: true

module Bookings
  # Raising brokerage against a booking.
  #
  # Hard-blocked past net income: a firm cannot invoice more than it earned.
  # The refusal carries the arithmetic so the app can explain itself rather
  # than just saying no.
  #
  # **The check and the insert happen under a row lock on the booking**, and
  # that is load-bearing rather than defensive. Without it this was a
  # read-then-write: two POSTs arriving in the same few milliseconds each read
  # the balance before either had inserted, both passed, and both saved. An
  # audit reproduced it against staging — a booking earning ₹1,00,000 took two
  # ₹1,00,000 invoices and ended at invoiceable_balance −₹1,00,000. A double-tap
  # on a slow connection is enough; no malice is needed.
  #
  # It is unrecoverable, which is what makes the lock non-negotiable: invoices
  # have no update and no destroy route, so a firm's books stay wrong forever
  # and every report sums them.
  class RaiseInvoice
    Result = Struct.new(:ok?, :invoice, :error_code, :error_message, :details, keyword_init: true)

    def initialize(booking:, attributes:, actor: nil)
      @booking = booking
      @attributes = attributes
      @actor = actor
    end

    def call
      amount = attributes[:amount].to_i
      invoice = nil

      # with_lock opens a transaction and SELECT ... FOR UPDATEs the booking, so
      # a second request for the same booking waits here rather than reading a
      # balance that is about to change. Reloading inside is the point: the
      # `booking` handed to us may already be stale.
      booking.with_lock do
        return cancelled_booking if booking.cancelled?

        available = booking.invoiceable_balance
        return over_invoiced(amount, available) if amount > available

        invoice = booking.invoices.new(attributes)
        invoice.firm = booking.firm
        invoice.save!

        AuditEvent.record!(subject: invoice, firm: booking.firm, actor:,
                           action: "invoice.raised", metadata: { amount:, number: invoice.number })
      end

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
