# frozen_string_literal: true

# Where the money is.
#
# Every booking carries a lead reference — the design's flow starts by searching
# leads by phone and says so outright: "every booking is tied to a lead record".
# One lead may carry several bookings (a client buying two units).
class CreateBookings < ActiveRecord::Migration[8.0]
  def change
    create_table :bookings, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: true, type: :uuid
      t.references :lead, null: false, foreign_key: true, type: :uuid
      t.references :project, foreign_key: true, type: :uuid
      t.references :created_by_user, foreign_key: { to_table: :users }, type: :uuid

      # Ours. The design's header shows the builder's own reference instead,
      # which is below — but a builder doesn't always give one.
      t.string :code, null: false

      t.string  :builder_ref_no
      t.string  :unit_no
      t.integer :carpet_area_sqft

      # Snapshotted from the lead at booking time: correcting a lead's name a
      # year later must not rewrite what was booked.
      t.string :customer_name
      t.string :customer_mobile

      t.date :booked_on, null: false

      # All whole rupees. See docs/schema.md for the money rule.
      t.bigint  :agreement_value, null: false
      t.decimal :commission_percent, precision: 5, scale: 2, null: false
      t.bigint  :kicker, null: false, default: 0
      t.bigint  :passback, null: false, default: 0

      # Stored, not derived — recomputed on every save so what a booking shows
      # can never drift from what the reports sum.
      t.bigint :net_income, null: false, default: 0

      t.text :other_details

      t.string   :status, null: false, default: "live"
      t.datetime :cancelled_at
      t.text     :cancellation_reason

      # Post-sales followup.
      t.date    :registration_done_on
      t.integer :client_paid_percent

      t.timestamps
    end

    add_index :bookings, [ :firm_id, :code ], unique: true
    add_index :bookings, [ :firm_id, :status ]
    add_index :bookings, [ :firm_id, :booked_on ]

    add_check_constraint :bookings, "status IN ('live', 'cancelled')", name: "bookings_status_check"
    add_check_constraint :bookings, "agreement_value >= 0", name: "bookings_agreement_value_check"
    add_check_constraint :bookings,
      "commission_percent >= 0 AND commission_percent <= 100",
      name: "bookings_commission_percent_check"
    add_check_constraint :bookings,
      "client_paid_percent IS NULL OR (client_paid_percent >= 0 AND client_paid_percent <= 100)",
      name: "bookings_client_paid_percent_check"

    # The design's four slots. Only "other" may repeat.
    create_table :booking_documents, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: true, type: :uuid
      t.references :booking, null: false, foreign_key: true, type: :uuid
      t.references :uploaded_by_user, foreign_key: { to_table: :users }, type: :uuid

      t.string :slot, null: false
      t.string :label

      t.timestamps
    end

    # Only 'other' may repeat; the rest are one per booking.
    add_index :booking_documents, [ :booking_id, :slot ], unique: true,
      where: "slot <> 'other'", name: "index_booking_documents_one_per_named_slot"

    add_check_constraint :booking_documents,
      "slot IN ('application_form', 'tagging_confirmation', 'lead_source_proof', 'other')",
      name: "booking_documents_slot_check"

    create_table :invoices, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: true, type: :uuid
      t.references :booking, null: false, foreign_key: true, type: :uuid

      # Entered by the broker (INV-2026-041) so it matches what they raised
      # outside the system. Unique per firm.
      t.string :number, null: false
      t.date   :issued_on, null: false
      t.bigint :amount, null: false
      t.string :comment

      t.string :status, null: false, default: "raised"

      t.timestamps
    end

    add_index :invoices, [ :firm_id, :number ], unique: true

    add_check_constraint :invoices, "status IN ('raised', 'cancelled')", name: "invoices_status_check"
    add_check_constraint :invoices, "amount > 0", name: "invoices_amount_check"

    create_table :collections, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: true, type: :uuid
      t.references :booking, null: false, foreign_key: true, type: :uuid
      # Nullable — the design allows an "Unlinked payment".
      t.references :invoice, foreign_key: true, type: :uuid

      t.date   :received_on, null: false
      t.bigint :amount, null: false
      t.string :transaction_no
      t.string :mode, null: false

      t.timestamps
    end

    add_index :collections, [ :firm_id, :received_on ]

    add_check_constraint :collections,
      "mode IN ('neft_rtgs', 'upi', 'cheque', 'cash')",
      name: "collections_mode_check"
    add_check_constraint :collections, "amount > 0", name: "collections_amount_check"
  end
end
