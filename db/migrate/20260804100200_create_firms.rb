# frozen_string_literal: true

# The tenant. Every firm-owned table in the app hangs off this one via firm_id.
class CreateFirms < ActiveRecord::Migration[8.0]
  def change
    create_table :firms, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :name, null: false
      t.string :legal_name
      t.string :slug, null: false
      # Human-readable identifier ops and brokers quote at each other
      # (CP-MH-04218). Distinct from the uuid, which never leaves the system.
      t.string :code, null: false

      t.string :status, null: false, default: "pending"

      t.string :primary_contact_name

      t.string :rera_number
      t.date   :rera_valid_till
      t.string :pan
      t.string :gst_number

      t.string :address_line1
      t.string :address_line2
      t.references :city, foreign_key: true, type: :uuid
      t.references :locality, foreign_key: true, type: :uuid
      t.string :pincode

      t.string :timezone, null: false, default: "Asia/Kolkata"
      t.string :currency, null: false, default: "INR"

      t.jsonb :settings, null: false, default: {}
      t.text :internal_notes

      t.datetime :activated_at
      t.datetime :suspended_at
      t.text     :suspension_reason

      t.timestamps
    end

    add_index :firms, :slug, unique: true
    add_index :firms, :code, unique: true
    add_index :firms, :status

    add_check_constraint :firms,
      "status IN ('pending', 'active', 'suspended', 'churned')",
      name: "firms_status_check"

    # Printed on the invoices a broker raises from a booking. Account number is
    # encrypted at the application layer (see the model) — ops can enter it but
    # it is never readable straight off the table.
    create_table :firm_bank_accounts, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: true, type: :uuid
      t.string :account_number, null: false
      t.string :ifsc, null: false
      t.string :bank_name, null: false
      t.string :holder_name, null: false
      t.boolean :primary, null: false, default: true
      t.timestamps
    end

    # One primary account per firm. Additional accounts are allowed but only one
    # can be the one invoices print.
    add_index :firm_bank_accounts, :firm_id,
      unique: true,
      where: "\"primary\" = true",
      name: "index_firm_bank_accounts_one_primary_per_firm"
  end
end
