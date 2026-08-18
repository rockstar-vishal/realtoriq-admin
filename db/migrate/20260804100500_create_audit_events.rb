# frozen_string_literal: true

# A record of consequential changes — firm status transitions, verification
# decisions, subscription changes.
#
# Written from day one but with no viewer UI in this build: the value is that
# the history exists when someone eventually asks "who suspended this firm and
# why", and that history can't be backfilled after the fact.
class CreateAuditEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :audit_events, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      # Polymorphic and nullable: the actor is an AdminUser from the panel, a
      # User from the broker app, or nobody at all for system transitions.
      t.references :actor, polymorphic: true, type: :uuid
      t.references :subject, polymorphic: true, null: false, type: :uuid

      # Denormalised so a firm's history stays queryable even after the subject
      # row is gone.
      t.references :firm, foreign_key: true, type: :uuid

      t.string :action, null: false
      t.jsonb  :metadata, null: false, default: {}
      t.string :ip

      t.datetime :created_at, null: false
    end

    add_index :audit_events, [ :firm_id, :created_at ]
    add_index :audit_events, [ :subject_type, :subject_id, :created_at ],
      name: "index_audit_events_on_subject_and_time"
  end
end
