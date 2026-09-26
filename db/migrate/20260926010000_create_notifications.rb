# frozen_string_literal: true

# In-app inbox plus the browser push subscriptions that deliver it.
# The inbox row is the record. Push is a best-effort copy of that row.
class CreateNotifications < ActiveRecord::Migration[8.0]
  def change
    create_table :notifications, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: true, type: :uuid
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :kind, null: false
      t.string :title, null: false
      t.text :body, null: false
      t.datetime :read_at
      t.jsonb :data, null: false, default: {}
      t.string :dedupe_key, null: false
      t.timestamps
    end
    add_index :notifications, [ :user_id, :dedupe_key ], unique: true
    add_index :notifications, [ :user_id, :read_at ]
    add_check_constraint :notifications,
      "kind IN ('followup_due', 'test')",
      name: "notifications_kind_check"

    create_table :push_subscriptions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: true, type: :uuid
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :auth_session, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      # Endpoint URLs are longer than varchar, and they are a delivery capability.
      t.text :endpoint, null: false
      t.text :p256dh, null: false
      t.text :auth_key, null: false
      t.string :content_encoding, null: false, default: "aes128gcm"
      t.string :user_agent
      t.datetime :last_success_at
      t.integer :failure_count, null: false, default: 0
      t.timestamps
    end
    add_index :push_subscriptions, :endpoint, unique: true

    # One global cursor for the follow-up scanner. Not firm-scoped: the job
    # runs with no tenant set and walks every firm.
    create_table :notification_dispatch_states, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :key, null: false
      t.datetime :last_dispatched_at
      t.timestamps
    end
    add_index :notification_dispatch_states, :key, unique: true

    add_index :leads, :next_action_at
  end
end
