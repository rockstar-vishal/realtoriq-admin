# frozen_string_literal: true

module Api
  module V1
    module CollectionSerializer
      def self.call(collection)
        {
          id: collection.id,
          received_on: collection.received_on,
          amount: collection.amount,
          mode: collection.mode,
          transaction_no: collection.transaction_no,
          # Null for the design's "Unlinked payment".
          invoice: collection.invoice && {
            id: collection.invoice_id, number: collection.invoice.number
          },
          proof_url: collection.proof.attached? ? BlobUrl.call(collection.proof) : nil,
          created_at: collection.created_at
        }
      end
    end
  end
end
