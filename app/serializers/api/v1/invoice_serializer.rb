# frozen_string_literal: true

module Api
  module V1
    module InvoiceSerializer
      def self.call(invoice)
        {
          id: invoice.id,
          number: invoice.number,
          issued_on: invoice.issued_on,
          amount: invoice.amount,
          comment: invoice.comment,
          status: invoice.status,
          collected: invoice.collected_total,
          # What may still be collected against this invoice — the per-invoice
          # cap the API enforces.
          collectable_balance: invoice.collectable_balance
        }
      end
    end
  end
end
