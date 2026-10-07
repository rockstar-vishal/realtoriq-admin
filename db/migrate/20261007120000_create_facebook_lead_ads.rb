# frozen_string_literal: true

# Facebook Lead Ads. Statuses are strings, like every other enum in this app.
# The spec's integers are LaunchIQ's storage; the names are the same.
class CreateFacebookLeadAds < ActiveRecord::Migration[8.0]
  def up
    create_table :facebook_connections, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, type: :uuid, foreign_key: true
      t.references :connected_by_user, null: false, type: :uuid,
        foreign_key: { to_table: :users, on_delete: :cascade }
      t.string :fb_user_id, null: false
      t.string :fb_user_name
      t.string :token_kind, null: false, default: "user_access"
      t.string :client_business_id
      t.text :access_token
      t.datetime :token_expires_at
      t.datetime :token_obtained_at
      t.datetime :last_health_check_at
      t.string :status, null: false, default: "active"
      t.string :error_code
      t.jsonb :error_details, null: false, default: {}
      t.timestamps
    end
    add_index :facebook_connections, [ :firm_id, :status ]
    add_index :facebook_connections, :firm_id, unique: true, where: "status = 'active'",
      name: "index_facebook_connections_one_active_per_firm"
    add_check_constraint :facebook_connections,
      "token_kind IN ('user_access', 'system_access')",
      name: "facebook_connections_token_kind_check"
    add_check_constraint :facebook_connections,
      "status IN ('active', 'invalid', 'disconnected')",
      name: "facebook_connections_status_check"

    create_table :facebook_pages, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, type: :uuid, foreign_key: true
      # Deleting the connection (the connecting user was removed) takes the
      # page rows with it. Disconnect does not delete the connection, so the
      # page setup stays.
      t.references :facebook_connection, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :page_id, null: false
      t.string :page_name, null: false
      t.text :page_access_token
      t.boolean :subscribed, null: false, default: false
      t.datetime :subscribed_at
      t.string :status, null: false, default: "unsubscribed"
      t.string :status_message
      t.jsonb :form_catalog, null: false, default: []
      t.datetime :forms_synced_at
      t.timestamps
    end
    add_index :facebook_pages, [ :firm_id, :page_id ], unique: true
    add_index :facebook_pages, :page_id
    add_check_constraint :facebook_pages,
      "status IN ('active', 'unsubscribed', 'error')",
      name: "facebook_pages_status_check"

    create_table :facebook_lead_forms, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, type: :uuid, foreign_key: true
      t.references :facebook_page, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :form_id, null: false
      t.string :form_name, null: false
      t.string :meta_status
      t.boolean :active, null: false, default: true
      t.jsonb :questions, null: false, default: []
      t.jsonb :field_mappings, null: false, default: {}
      t.references :project, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :property, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :assigned_user, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :lead_source, type: :uuid, foreign_key: { on_delete: :nullify }
      t.timestamps
    end
    add_index :facebook_lead_forms, :form_id, unique: true
    add_check_constraint :facebook_lead_forms,
      "project_id IS NULL OR property_id IS NULL",
      name: "facebook_lead_forms_one_listing"

    create_table :facebook_lead_imports, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, type: :uuid, foreign_key: true
      t.references :facebook_page, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :facebook_lead_form, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :lead, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :leadgen_id, null: false
      t.string :status, null: false, default: "pending"
      t.jsonb :raw_payload, null: false, default: {}
      t.jsonb :fetched_payload, null: false, default: {}
      t.text :error_message
      t.jsonb :error_details, null: false, default: {}
      t.integer :retry_count, null: false, default: 0
      t.datetime :next_attempt_at
      t.datetime :processing_started_at
      t.datetime :processed_at
      t.datetime :failure_alert_pending_at
      t.datetime :failure_alerted_at
      t.timestamps
    end
    add_index :facebook_lead_imports, :leadgen_id, unique: true
    add_index :facebook_lead_imports, [ :firm_id, :status ]
    add_index :facebook_lead_imports, [ :firm_id, :created_at ]
    add_index :facebook_lead_imports, :failure_alert_pending_at,
      where: "failure_alert_pending_at IS NOT NULL",
      name: "index_facebook_lead_imports_on_failure_alert_pending"
    add_check_constraint :facebook_lead_imports,
      "status IN ('pending', 'processing', 'created', 'failed', 'dead', 'duplicate')",
      name: "facebook_lead_imports_status_check"

    create_table :facebook_import_alert_states, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, type: :uuid, foreign_key: true, index: { unique: true }
      t.datetime :last_failure_emailed_at
      t.datetime :last_duplicate_notified_at
      t.timestamps
    end

    create_table :facebook_oauth_attempts, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :user, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :nonce_digest, null: false
      t.string :status, null: false, default: "started"
      t.text :result
      t.string :error_code
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_check_constraint :facebook_oauth_attempts,
      "status IN ('started', 'completed', 'failed', 'consumed')",
      name: "facebook_oauth_attempts_status_check"

    remove_check_constraint :notifications, name: "notifications_kind_check"
    add_check_constraint :notifications,
      "kind IN ('followup_due', 'test', 'training_published', 'marketplace_enquiry', 'inbound_enquiry', 'facebook')",
      name: "notifications_kind_check"
  end

  def down
    remove_check_constraint :notifications, name: "notifications_kind_check"
    add_check_constraint :notifications,
      "kind IN ('followup_due', 'test', 'training_published', 'marketplace_enquiry', 'inbound_enquiry')",
      name: "notifications_kind_check"

    drop_table :facebook_oauth_attempts
    drop_table :facebook_import_alert_states
    drop_table :facebook_lead_imports
    drop_table :facebook_lead_forms
    drop_table :facebook_pages
    drop_table :facebook_connections
  end
end
