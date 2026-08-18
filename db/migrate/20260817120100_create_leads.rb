# frozen_string_literal: true

# The core CRM object. Everything downstream references it: a booking cannot
# exist without a lead, and two of the four reports aggregate over lead data.
class CreateLeads < ActiveRecord::Migration[8.0]
  def change
    create_table :leads, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: true, type: :uuid

      # L-2291 in the design. Sequential per firm rather than random, because
      # brokers read these numbers to each other over the phone.
      t.string :code, null: false

      # Nullable on purpose: brokers get a number off a portal before they get
      # a name, and forcing one means "Unknown" typed into a thousand records.
      t.string :name
      t.string :mobile, null: false
      t.string :alt_mobile
      t.string :email

      t.string :transaction_type, null: false

      # Asked for sale leads, and deliberately not asked for rentals — the
      # design's form drops the question entirely. Enforced in the model.
      t.references :property_type, foreign_key: true, type: :uuid

      # Whole rupees. For a rental lead this is monthly rent.
      t.bigint :budget_min
      t.bigint :budget_max

      t.date :possession_by

      t.references :lead_source, foreign_key: true, type: :uuid
      # "Referral — V. Rao": which referral, beyond the source category.
      t.string :source_detail

      t.references :lead_status, null: false, foreign_key: true, type: :uuid
      t.references :assigned_user, foreign_key: { to_table: :users }, type: :uuid

      t.datetime :next_action_at
      t.string   :next_action_note

      # Set the first time a visit activity is logged, so the design's
      # "visited" badge cannot drift from the timeline.
      t.datetime :first_visit_at

      t.string   :dead_reason
      t.datetime :dead_at
      t.datetime :booked_at

      t.text :notes

      t.timestamps
    end

    add_index :leads, [ :firm_id, :code ], unique: true
    add_index :leads, [ :firm_id, :lead_status_id ]
    add_index :leads, [ :firm_id, :mobile ]
    add_index :leads, [ :firm_id, :next_action_at ]
    # The agent-visibility scope runs on every list request.
    add_index :leads, [ :firm_id, :assigned_user_id ]

    add_check_constraint :leads,
      "transaction_type IN ('sale', 'rent')",
      name: "leads_transaction_type_check"

    add_check_constraint :leads,
      "budget_max IS NULL OR budget_min IS NULL OR budget_max >= budget_min",
      name: "leads_budget_range_check"

    # The multi-select "Preferred configuration".
    create_table :lead_typologies, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :lead, null: false, foreign_key: true, type: :uuid
      t.references :typology, null: false, foreign_key: true, type: :uuid
      t.timestamps
    end

    add_index :lead_typologies, [ :lead_id, :typology_id ], unique: true
  end
end
