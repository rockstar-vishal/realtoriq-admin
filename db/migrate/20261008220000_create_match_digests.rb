# frozen_string_literal: true

# One current match list per firm. The 12-hour job overwrites it. The super
# admin is told when something new is on the list; the row itself is the page.
class CreateMatchDigests < ActiveRecord::Migration[8.0]
  KINDS_WITH_DIGEST = "kind IN ('followup_due', 'test', 'training_published', 'marketplace_enquiry', 'inbound_enquiry', 'facebook', 'match_digest')"
  KINDS_BEFORE = "kind IN ('followup_due', 'test', 'training_published', 'marketplace_enquiry', 'inbound_enquiry', 'facebook')"

  def up
    create_table :match_digests, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: true, type: :uuid, index: { unique: true }
      t.datetime :generated_at, null: false
      t.string :fingerprint, null: false
      t.jsonb :lead_items, null: false, default: []
      t.jsonb :listing_items, null: false, default: []
      t.boolean :notification_pending, null: false, default: false
      t.string :notified_fingerprint
      t.timestamps
    end

    add_index :match_digests, :generated_at
    add_index :match_digests, :notification_pending, where: "notification_pending"

    remove_check_constraint :notifications, name: "notifications_kind_check"
    add_check_constraint :notifications, KINDS_WITH_DIGEST, name: "notifications_kind_check"
  end

  def down
    remove_check_constraint :notifications, name: "notifications_kind_check"
    add_check_constraint :notifications, KINDS_BEFORE, name: "notifications_kind_check"
    drop_table :match_digests
  end
end
