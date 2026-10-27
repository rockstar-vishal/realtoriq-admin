# frozen_string_literal: true

# One row per ops alert. last_reported_at is the newest failure already
# emailed. last_emailed_at is when that email went out, so a burst waits.
class CreateOpsAlertMarks < ActiveRecord::Migration[8.0]
  def change
    create_table :ops_alert_marks, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :name, null: false
      t.datetime :last_reported_at
      t.datetime :last_emailed_at
      t.timestamps
    end

    add_index :ops_alert_marks, :name, unique: true
  end
end
