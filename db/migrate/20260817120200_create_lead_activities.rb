# frozen_string_literal: true

# Two tables that look similar and are not.
#
# `lead_activities` is the human timeline — what the broker did, rendered on the
# lead page. `lead_status_changes` is the machine record of pipeline movement,
# and exists separately because the dead-leads report needs *the month a lead
# died*. A mutable status column cannot answer that, and reconstructing it from
# free-text activities would be guesswork.
class CreateLeadActivities < ActiveRecord::Migration[8.0]
  def change
    create_table :lead_activities, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: true, type: :uuid
      t.references :lead, null: false, foreign_key: true, type: :uuid
      # Null when the system wrote it rather than a person.
      t.references :user, foreign_key: true, type: :uuid

      t.string :kind, null: false
      t.text   :body
      t.string :outcome

      # Separate from created_at: a broker logs this evening the call they made
      # this morning, and the timeline should show when it happened.
      t.datetime :occurred_at, null: false

      t.timestamps
    end

    add_index :lead_activities, [ :lead_id, :occurred_at ]
    add_index :lead_activities, [ :firm_id, :occurred_at ]

    add_check_constraint :lead_activities,
      "kind IN ('call', 'whatsapp', 'visit', 'note', 'status_change')",
      name: "lead_activities_kind_check"

    create_table :lead_status_changes, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: true, type: :uuid
      t.references :lead, null: false, foreign_key: true, type: :uuid
      # Null for the very first assignment, when the lead was created.
      t.references :from_status, foreign_key: { to_table: :lead_statuses }, type: :uuid
      t.references :to_status, null: false, foreign_key: { to_table: :lead_statuses }, type: :uuid
      t.references :user, foreign_key: true, type: :uuid

      t.datetime :changed_at, null: false

      t.datetime :created_at, null: false
    end

    # The dead-leads report groups by month over this.
    add_index :lead_status_changes, [ :firm_id, :changed_at ]
    add_index :lead_status_changes, [ :lead_id, :changed_at ]
  end
end
