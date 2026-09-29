# frozen_string_literal: true

# A visit pass turbo issued for one of this firm's leads. The pass code is
# what the refresh button sends. Status lives here so the screen can show the
# last fetch without calling turbo again inside the six-hour window.
class CreateLeadVisitPasses < ActiveRecord::Migration[8.0]
  def change
    create_table :lead_visit_passes, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: true, type: :uuid
      t.references :lead, null: false, foreign_key: true, type: :uuid
      t.references :project, null: false, foreign_key: true, type: :uuid
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.string :pass_code, null: false
      t.string :phone_suffix, null: false
      t.datetime :tentative_visit_planned, null: false
      t.string :turbo_status, null: false, default: "unused"
      t.string :turbo_lead_code
      t.string :turbo_status_name
      t.jsonb :status_detail, null: false, default: {}
      t.datetime :last_followup_at
      t.text :last_followup_comment
      t.datetime :next_followup_at
      t.datetime :last_fetched_at
      t.timestamps
    end

    add_index :lead_visit_passes, :pass_code, unique: true
    add_index :lead_visit_passes, [ :lead_id, :project_id ]
  end
end
