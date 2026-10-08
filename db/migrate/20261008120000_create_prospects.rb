# frozen_string_literal: true

# A firm's calling list, separate from leads. Rows are hard-deleted on purpose:
# the list is disposable, and a manager downloads a backup first. See
# PROJECT_THEORY invariant 13.
class CreateProspects < ActiveRecord::Migration[8.0]
  def change
    create_table :prospects, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: true, type: :uuid
      t.string :name
      t.string :mobile, null: false
      t.text :comment
      t.string :status, null: false, default: "new"
      t.references :project, foreign_key: true, type: :uuid
      t.references :property, foreign_key: true, type: :uuid
      # Nullify so deleting an untouched lead does not have to delete the prospect first.
      t.references :lead, foreign_key: { on_delete: :nullify }, type: :uuid, index: { unique: true }
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }, type: :uuid
      t.datetime :next_action_at
      t.timestamps
    end

    add_index :prospects, [ :firm_id, :mobile ], unique: true
    add_index :prospects, [ :firm_id, :status ]
    add_index :prospects, [ :firm_id, :next_action_at ]

    add_check_constraint :prospects,
      "status IN ('new', 'following', 'interested', 'not_interested')",
      name: "prospects_status_check"
    add_check_constraint :prospects,
      "project_id IS NULL OR property_id IS NULL",
      name: "prospects_one_inventory_check"
    add_check_constraint :prospects,
      "mobile ~ '^\\+91[6-9][0-9]{9}$'",
      name: "prospects_mobile_check"

    create_table :prospect_followups, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: true, type: :uuid
      t.references :prospect, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :user, foreign_key: { on_delete: :nullify }, type: :uuid
      t.boolean :connected, null: false
      t.text :notes, null: false
      t.datetime :next_action_at
      t.string :outcome, null: false
      t.timestamps
    end

    add_index :prospect_followups, [ :prospect_id, :created_at ]

    add_check_constraint :prospect_followups,
      "outcome IN ('retry', 'not_sure', 'interested', 'not_interested')",
      name: "prospect_followups_outcome_check"
  end
end
