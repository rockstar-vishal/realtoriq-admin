# frozen_string_literal: true

module Api
  module V1
    module BookingSerializer
      class << self
        def list(booking)
          {
            id: booking.id,
            code: booking.code,
            builder_ref_no: booking.builder_ref_no,
            customer_name: booking.customer_name,
            customer_mobile: booking.customer_mobile,
            project: booking.project && { id: booking.project_id, name: booking.project.name },
            unit_no: booking.unit_no,
            booked_on: booking.booked_on,
            status: booking.status,
            agreement_value: booking.agreement_value,
            net_income: booking.net_income,
            # The design's list card shows all three side by side.
            invoiced: booking.invoiced_total,
            collected: booking.collected_total,
            outstanding: booking.outstanding,
            registration_done: booking.registration_done?,
            registration_done_on: booking.registration_done_on,
            client_paid_percent: booking.client_paid_percent,
            lead: { id: booking.lead_id, code: booking.lead&.code }
          }
        end

        def detail(booking)
          list(booking).merge(
            carpet_area_sqft: booking.carpet_area_sqft,
            other_details: booking.other_details,
            # The revenue block, itemised the way the design's screen breaks it
            # down — so the client never recomputes money.
            revenue: {
              agreement_value: booking.agreement_value,
              commission_percent: booking.commission_percent.to_f,
              commission_amount: booking.commission_amount,
              kicker: booking.kicker,
              passback: booking.passback,
              net_income: booking.net_income,
              invoiceable_balance: booking.invoiceable_balance
            },
            cancelled_at: booking.cancelled_at,
            cancellation_reason: booking.cancellation_reason,
            documents: booking.booking_documents.map { |d| document(d) },
            invoices: booking.invoices.recent_first.map { |i| InvoiceSerializer.call(i) },
            collections: booking.collections.recent_first.map { |c| CollectionSerializer.call(c) },
            created_at: booking.created_at,
            updated_at: booking.updated_at
          )
        end

        def document(doc)
          {
            id: doc.id,
            slot: doc.slot,
            label: doc.display_label,
            filename: doc.file.attached? ? doc.file.filename.to_s : nil,
            byte_size: doc.file.attached? ? doc.file.byte_size : nil,
            url: doc.file.attached? ? BlobUrl.call(doc.file) : nil,
            uploaded_at: doc.created_at
          }
        end
      end
    end
  end
end
