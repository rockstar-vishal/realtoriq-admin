# frozen_string_literal: true

# Follow-up comments are rows, not a stamped string on the lead. NCD on the
# lead is copied from a followup when one is saved with a datetime. Existing
# next_action_note values become one followup per lead, then the column goes.
class CreateLeadFollowups < ActiveRecord::Migration[8.0]
  def up
    create_table :lead_followups, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: true, type: :uuid
      t.references :lead, null: false, foreign_key: true, type: :uuid
      t.references :user, foreign_key: { on_delete: :nullify }, type: :uuid

      t.text :comment, null: false
      t.datetime :next_action_at

      t.timestamps
    end

    add_index :lead_followups, [ :lead_id, :created_at ]

    execute <<~SQL.squish
      INSERT INTO lead_followups (id, firm_id, lead_id, user_id, comment, next_action_at, created_at, updated_at)
      SELECT gen_random_uuid(), firm_id, id, NULL, next_action_note, next_action_at, NOW(), NOW()
      FROM leads
      WHERE next_action_note IS NOT NULL AND btrim(next_action_note) <> ''
    SQL

    remove_column :leads, :next_action_note
  end

  def down
    add_column :leads, :next_action_note, :string

    execute <<~SQL.squish
      UPDATE leads
      SET next_action_note = latest.comment
      FROM (
        SELECT DISTINCT ON (lead_id) lead_id, comment
        FROM lead_followups
        ORDER BY lead_id, created_at DESC
      ) latest
      WHERE leads.id = latest.lead_id
    SQL

    drop_table :lead_followups
  end
end
