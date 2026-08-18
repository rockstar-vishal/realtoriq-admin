# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_08_18_160000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "active_storage_attachments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.uuid "record_id", null: false
    t.uuid "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "admin_sessions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "admin_user_id", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.datetime "last_seen_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["admin_user_id"], name: "index_admin_sessions_on_admin_user_id"
  end

  create_table "admin_users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.string "email", null: false
    t.string "password_digest", null: false
    t.datetime "last_login_at"
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_admin_users_on_email", unique: true
  end

  create_table "audit_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "actor_type"
    t.uuid "actor_id"
    t.string "subject_type", null: false
    t.uuid "subject_id", null: false
    t.uuid "firm_id"
    t.string "action", null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "ip"
    t.datetime "created_at", null: false
    t.index ["actor_type", "actor_id"], name: "index_audit_events_on_actor"
    t.index ["firm_id", "created_at"], name: "index_audit_events_on_firm_id_and_created_at"
    t.index ["firm_id"], name: "index_audit_events_on_firm_id"
    t.index ["subject_type", "subject_id", "created_at"], name: "index_audit_events_on_subject_and_time"
    t.index ["subject_type", "subject_id"], name: "index_audit_events_on_subject"
  end

  create_table "auth_sessions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.uuid "firm_id", null: false
    t.string "refresh_token_digest", null: false
    t.string "device_id"
    t.string "device_name"
    t.string "platform"
    t.string "app_version"
    t.string "user_agent"
    t.string "ip"
    t.datetime "last_used_at"
    t.datetime "expires_at", null: false
    t.datetime "revoked_at"
    t.string "revoked_reason"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["firm_id"], name: "index_auth_sessions_on_firm_id"
    t.index ["refresh_token_digest"], name: "index_auth_sessions_on_refresh_token_digest", unique: true
    t.index ["user_id", "device_id"], name: "index_auth_sessions_one_live_per_device", unique: true, where: "((revoked_at IS NULL) AND (device_id IS NOT NULL))"
    t.index ["user_id", "revoked_at"], name: "index_auth_sessions_on_user_id_and_revoked_at"
    t.index ["user_id"], name: "index_auth_sessions_on_user_id"
  end

  create_table "booking_documents", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "firm_id", null: false
    t.uuid "booking_id", null: false
    t.uuid "uploaded_by_user_id"
    t.string "slot", null: false
    t.string "label"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["booking_id", "slot"], name: "index_booking_documents_one_per_named_slot", unique: true, where: "((slot)::text <> 'other'::text)"
    t.index ["booking_id"], name: "index_booking_documents_on_booking_id"
    t.index ["firm_id"], name: "index_booking_documents_on_firm_id"
    t.index ["uploaded_by_user_id"], name: "index_booking_documents_on_uploaded_by_user_id"
    t.check_constraint "slot::text = ANY (ARRAY['application_form'::character varying::text, 'tagging_confirmation'::character varying::text, 'lead_source_proof'::character varying::text, 'other'::character varying::text])", name: "booking_documents_slot_check"
  end

  create_table "bookings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "firm_id", null: false
    t.uuid "lead_id", null: false
    t.uuid "project_id"
    t.uuid "created_by_user_id"
    t.string "code", null: false
    t.string "builder_ref_no"
    t.string "unit_no"
    t.integer "carpet_area_sqft"
    t.string "customer_name"
    t.string "customer_mobile"
    t.date "booked_on", null: false
    t.bigint "agreement_value", null: false
    t.decimal "commission_percent", precision: 5, scale: 2, null: false
    t.bigint "kicker", default: 0, null: false
    t.bigint "passback", default: 0, null: false
    t.bigint "net_income", default: 0, null: false
    t.text "other_details"
    t.string "status", default: "live", null: false
    t.datetime "cancelled_at"
    t.text "cancellation_reason"
    t.date "registration_done_on"
    t.integer "client_paid_percent"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_user_id"], name: "index_bookings_on_created_by_user_id"
    t.index ["firm_id", "booked_on"], name: "index_bookings_on_firm_id_and_booked_on"
    t.index ["firm_id", "code"], name: "index_bookings_on_firm_id_and_code", unique: true
    t.index ["firm_id", "status"], name: "index_bookings_on_firm_id_and_status"
    t.index ["firm_id"], name: "index_bookings_on_firm_id"
    t.index ["lead_id"], name: "index_bookings_on_lead_id"
    t.index ["project_id"], name: "index_bookings_on_project_id"
    t.check_constraint "agreement_value >= 0", name: "bookings_agreement_value_check"
    t.check_constraint "client_paid_percent IS NULL OR client_paid_percent >= 0 AND client_paid_percent <= 100", name: "bookings_client_paid_percent_check"
    t.check_constraint "commission_percent >= 0::numeric AND commission_percent <= 100::numeric", name: "bookings_commission_percent_check"
    t.check_constraint "status::text = ANY (ARRAY['live'::character varying::text, 'cancelled'::character varying::text])", name: "bookings_status_check"
  end

  create_table "builders", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.string "slug", null: false
    t.string "website"
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "firm_id"
    t.index ["firm_id", "name"], name: "index_builders_on_firm_and_name", unique: true, where: "(firm_id IS NOT NULL)"
    t.index ["firm_id", "slug"], name: "index_builders_on_firm_and_slug", unique: true, where: "(firm_id IS NOT NULL)"
    t.index ["firm_id"], name: "index_builders_on_firm_id"
    t.index ["name"], name: "index_builders_on_name_global", unique: true, where: "(firm_id IS NULL)"
    t.index ["slug"], name: "index_builders_on_slug_global", unique: true, where: "(firm_id IS NULL)"
  end

  create_table "buildings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "firm_id", null: false
    t.string "name", null: false
    t.uuid "city_id", null: false
    t.uuid "locality_id", null: false
    t.string "address"
    t.decimal "lat", precision: 10, scale: 7
    t.decimal "lng", precision: 10, scale: 7
    t.string "google_place_id"
    t.boolean "has_pool", default: false, null: false
    t.boolean "has_gym", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["city_id"], name: "index_buildings_on_city_id"
    t.index ["firm_id", "city_id"], name: "index_buildings_on_firm_id_and_city_id"
    t.index ["firm_id", "name", "locality_id"], name: "index_buildings_on_firm_id_and_name_and_locality_id", unique: true
    t.index ["firm_id"], name: "index_buildings_on_firm_id"
    t.index ["locality_id"], name: "index_buildings_on_locality_id"
  end

  create_table "cities", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.string "state", null: false
    t.string "country_code", default: "IN", null: false
    t.string "slug", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "state_code", null: false
    t.index ["name", "state"], name: "index_cities_on_name_and_state", unique: true
    t.index ["slug"], name: "index_cities_on_slug", unique: true
  end

  create_table "collections", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "firm_id", null: false
    t.uuid "booking_id", null: false
    t.uuid "invoice_id"
    t.date "received_on", null: false
    t.bigint "amount", null: false
    t.string "transaction_no"
    t.string "mode", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["booking_id"], name: "index_collections_on_booking_id"
    t.index ["firm_id", "received_on"], name: "index_collections_on_firm_id_and_received_on"
    t.index ["firm_id"], name: "index_collections_on_firm_id"
    t.index ["invoice_id"], name: "index_collections_on_invoice_id"
    t.check_constraint "amount > 0", name: "collections_amount_check"
    t.check_constraint "mode::text = ANY (ARRAY['neft_rtgs'::character varying::text, 'upi'::character varying::text, 'cheque'::character varying::text, 'cash'::character varying::text])", name: "collections_mode_check"
  end

  create_table "contact_channels", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "firm_id", null: false
    t.string "kind", null: false
    t.string "value", null: false
    t.string "verification_state", default: "unverified", null: false
    t.datetime "verified_at"
    t.uuid "verified_by_user_id"
    t.integer "verification_attempts", default: 0, null: false
    t.datetime "last_code_sent_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["firm_id", "kind"], name: "index_contact_channels_on_firm_id_and_kind", unique: true
    t.index ["firm_id"], name: "index_contact_channels_on_firm_id"
    t.index ["verified_by_user_id"], name: "index_contact_channels_on_verified_by_user_id"
    t.check_constraint "kind::text = ANY (ARRAY['email'::character varying::text, 'mobile'::character varying::text, 'whatsapp'::character varying::text])", name: "contact_channels_kind_check"
    t.check_constraint "verification_state::text = ANY (ARRAY['unverified'::character varying::text, 'pending'::character varying::text, 'verified'::character varying::text, 'failed'::character varying::text])", name: "contact_channels_verification_state_check"
  end

  create_table "firm_bank_accounts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "firm_id", null: false
    t.string "account_number", null: false
    t.string "ifsc", null: false
    t.string "bank_name", null: false
    t.string "holder_name", null: false
    t.boolean "primary", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["firm_id"], name: "index_firm_bank_accounts_on_firm_id"
    t.index ["firm_id"], name: "index_firm_bank_accounts_one_primary_per_firm", unique: true, where: "(\"primary\" = true)"
  end

  create_table "firms", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.string "legal_name"
    t.string "slug", null: false
    t.string "code", null: false
    t.string "status", default: "pending", null: false
    t.string "primary_contact_name"
    t.string "rera_number"
    t.date "rera_valid_till"
    t.string "pan"
    t.string "gst_number"
    t.string "address_line1"
    t.string "address_line2"
    t.uuid "city_id"
    t.uuid "locality_id"
    t.string "pincode"
    t.string "timezone", default: "Asia/Kolkata", null: false
    t.string "currency", default: "INR", null: false
    t.jsonb "settings", default: {}, null: false
    t.text "internal_notes"
    t.datetime "activated_at"
    t.datetime "suspended_at"
    t.text "suspension_reason"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["city_id"], name: "index_firms_on_city_id"
    t.index ["code"], name: "index_firms_on_code", unique: true
    t.index ["locality_id"], name: "index_firms_on_locality_id"
    t.index ["slug"], name: "index_firms_on_slug", unique: true
    t.index ["status"], name: "index_firms_on_status"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'active'::character varying::text, 'suspended'::character varying::text, 'churned'::character varying::text])", name: "firms_status_check"
  end

  create_table "invoices", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "firm_id", null: false
    t.uuid "booking_id", null: false
    t.string "number", null: false
    t.date "issued_on", null: false
    t.bigint "amount", null: false
    t.string "comment"
    t.string "status", default: "raised", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["booking_id"], name: "index_invoices_on_booking_id"
    t.index ["firm_id", "number"], name: "index_invoices_on_firm_id_and_number", unique: true
    t.index ["firm_id"], name: "index_invoices_on_firm_id"
    t.check_constraint "amount > 0", name: "invoices_amount_check"
    t.check_constraint "status::text = ANY (ARRAY['raised'::character varying::text, 'cancelled'::character varying::text])", name: "invoices_status_check"
  end

  create_table "lead_activities", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "firm_id", null: false
    t.uuid "lead_id", null: false
    t.uuid "user_id"
    t.string "kind", null: false
    t.text "body"
    t.string "outcome"
    t.datetime "occurred_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["firm_id", "occurred_at"], name: "index_lead_activities_on_firm_id_and_occurred_at"
    t.index ["firm_id"], name: "index_lead_activities_on_firm_id"
    t.index ["lead_id", "occurred_at"], name: "index_lead_activities_on_lead_id_and_occurred_at"
    t.index ["lead_id"], name: "index_lead_activities_on_lead_id"
    t.index ["user_id"], name: "index_lead_activities_on_user_id"
    t.check_constraint "kind::text = ANY (ARRAY['call'::character varying::text, 'whatsapp'::character varying::text, 'visit'::character varying::text, 'note'::character varying::text, 'status_change'::character varying::text])", name: "lead_activities_kind_check"
  end

  create_table "lead_sources", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.string "code", null: false
    t.string "category", default: "other", null: false
    t.integer "sort_order", default: 0, null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_lead_sources_on_code", unique: true
  end

  create_table "lead_status_changes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "firm_id", null: false
    t.uuid "lead_id", null: false
    t.uuid "from_status_id"
    t.uuid "to_status_id", null: false
    t.uuid "user_id"
    t.datetime "changed_at", null: false
    t.datetime "created_at", null: false
    t.index ["firm_id", "changed_at"], name: "index_lead_status_changes_on_firm_id_and_changed_at"
    t.index ["firm_id"], name: "index_lead_status_changes_on_firm_id"
    t.index ["from_status_id"], name: "index_lead_status_changes_on_from_status_id"
    t.index ["lead_id", "changed_at"], name: "index_lead_status_changes_on_lead_id_and_changed_at"
    t.index ["lead_id"], name: "index_lead_status_changes_on_lead_id"
    t.index ["to_status_id"], name: "index_lead_status_changes_on_to_status_id"
    t.index ["user_id"], name: "index_lead_status_changes_on_user_id"
  end

  create_table "lead_statuses", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.string "code", null: false
    t.string "color"
    t.integer "sort_order", default: 0, null: false
    t.boolean "is_dead", default: false, null: false
    t.boolean "is_booked", default: false, null: false
    t.boolean "is_terminal", default: false, null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_lead_statuses_on_code", unique: true
  end

  create_table "lead_typologies", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "lead_id", null: false
    t.uuid "typology_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["lead_id", "typology_id"], name: "index_lead_typologies_on_lead_id_and_typology_id", unique: true
    t.index ["lead_id"], name: "index_lead_typologies_on_lead_id"
    t.index ["typology_id"], name: "index_lead_typologies_on_typology_id"
  end

  create_table "leads", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "firm_id", null: false
    t.string "code", null: false
    t.string "name"
    t.string "mobile", null: false
    t.string "alt_mobile"
    t.string "email"
    t.string "transaction_type", null: false
    t.uuid "property_type_id"
    t.bigint "budget_min"
    t.bigint "budget_max"
    t.date "possession_by"
    t.uuid "lead_source_id"
    t.string "source_detail"
    t.uuid "lead_status_id", null: false
    t.uuid "assigned_user_id"
    t.datetime "next_action_at"
    t.string "next_action_note"
    t.datetime "first_visit_at"
    t.string "dead_reason"
    t.datetime "dead_at"
    t.datetime "booked_at"
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["assigned_user_id"], name: "index_leads_on_assigned_user_id"
    t.index ["firm_id", "assigned_user_id"], name: "index_leads_on_firm_id_and_assigned_user_id"
    t.index ["firm_id", "code"], name: "index_leads_on_firm_id_and_code", unique: true
    t.index ["firm_id", "lead_status_id"], name: "index_leads_on_firm_id_and_lead_status_id"
    t.index ["firm_id", "mobile"], name: "index_leads_on_firm_id_and_mobile"
    t.index ["firm_id", "next_action_at"], name: "index_leads_on_firm_id_and_next_action_at"
    t.index ["firm_id"], name: "index_leads_on_firm_id"
    t.index ["lead_source_id"], name: "index_leads_on_lead_source_id"
    t.index ["lead_status_id"], name: "index_leads_on_lead_status_id"
    t.index ["property_type_id"], name: "index_leads_on_property_type_id"
    t.check_constraint "budget_max IS NULL OR budget_min IS NULL OR budget_max >= budget_min", name: "leads_budget_range_check"
    t.check_constraint "transaction_type::text = ANY (ARRAY['sale'::character varying::text, 'rent'::character varying::text])", name: "leads_transaction_type_check"
  end

  create_table "localities", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "city_id", null: false
    t.string "name", null: false
    t.string "pincode"
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["city_id", "name"], name: "index_localities_on_city_id_and_name", unique: true
    t.index ["city_id"], name: "index_localities_on_city_id"
  end

  create_table "one_time_codes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "purpose", null: false
    t.string "destination", null: false
    t.uuid "user_id"
    t.uuid "contact_channel_id"
    t.string "code_digest", null: false
    t.datetime "expires_at", null: false
    t.datetime "consumed_at"
    t.integer "attempts", default: 0, null: false
    t.integer "max_attempts", default: 5, null: false
    t.string "request_ip"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["contact_channel_id"], name: "index_one_time_codes_on_contact_channel_id"
    t.index ["expires_at"], name: "index_one_time_codes_on_expires_at"
    t.index ["purpose", "destination", "created_at"], name: "index_one_time_codes_on_purpose_and_destination_and_created_at"
    t.index ["user_id"], name: "index_one_time_codes_on_user_id"
    t.check_constraint "purpose::text = ANY (ARRAY['login'::character varying::text, 'verify_email'::character varying::text, 'verify_mobile'::character varying::text, 'verify_whatsapp'::character varying::text])", name: "one_time_codes_purpose_check"
  end

  create_table "plans", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.string "code", null: false
    t.bigint "price", default: 0, null: false
    t.string "interval", default: "month", null: false
    t.integer "max_users"
    t.integer "max_devices", default: 3, null: false
    t.jsonb "features", default: {}, null: false
    t.boolean "active", default: true, null: false
    t.integer "sort_order", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_plans_on_code", unique: true
    t.check_constraint "\"interval\"::text = ANY (ARRAY['month'::character varying::text, 'year'::character varying::text])", name: "plans_interval_check"
    t.check_constraint "price >= 0", name: "plans_price_check"
  end

  create_table "project_typologies", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "project_id", null: false
    t.uuid "typology_id", null: false
    t.bigint "starting_price"
    t.integer "starting_carpet_sqft"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "typology_id"], name: "index_project_typologies_on_project_id_and_typology_id", unique: true
    t.index ["project_id"], name: "index_project_typologies_on_project_id"
    t.index ["typology_id"], name: "index_project_typologies_on_typology_id"
  end

  create_table "projects", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "firm_id", null: false
    t.string "name", null: false
    t.uuid "builder_id", null: false
    t.uuid "city_id", null: false
    t.uuid "locality_id"
    t.string "address"
    t.decimal "lat", precision: 10, scale: 7
    t.decimal "lng", precision: 10, scale: 7
    t.string "google_place_id"
    t.bigint "starting_budget", null: false
    t.date "possession_on"
    t.string "possession_label"
    t.string "rera_number"
    t.decimal "brokerage_percent", precision: 5, scale: 2
    t.string "promo_text"
    t.date "promo_ends_on"
    t.string "status", default: "active", null: false
    t.string "source", default: "own", null: false
    t.string "external_ref"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["builder_id"], name: "index_projects_on_builder_id"
    t.index ["city_id"], name: "index_projects_on_city_id"
    t.index ["firm_id", "builder_id"], name: "index_projects_on_firm_id_and_builder_id"
    t.index ["firm_id", "city_id"], name: "index_projects_on_firm_id_and_city_id"
    t.index ["firm_id", "status"], name: "index_projects_on_firm_id_and_status"
    t.index ["firm_id"], name: "index_projects_on_firm_id"
    t.index ["locality_id"], name: "index_projects_on_locality_id"
    t.index ["source", "external_ref"], name: "index_projects_on_source_and_external_ref", unique: true, where: "(external_ref IS NOT NULL)"
    t.check_constraint "source::text = ANY (ARRAY['own'::character varying::text, 'catalog'::character varying::text])", name: "projects_source_check"
    t.check_constraint "starting_budget >= 0", name: "projects_starting_budget_check"
    t.check_constraint "status::text = ANY (ARRAY['active'::character varying::text, 'archived'::character varying::text])", name: "projects_status_check"
  end

  create_table "properties", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "firm_id", null: false
    t.uuid "building_id", null: false
    t.uuid "typology_id", null: false
    t.string "listing_for", null: false
    t.string "floor_band"
    t.bigint "price", null: false
    t.integer "carpet_area_sqft"
    t.date "available_from"
    t.text "description"
    t.text "confidential_note"
    t.string "status", default: "available", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["building_id"], name: "index_properties_on_building_id"
    t.index ["firm_id", "building_id"], name: "index_properties_on_firm_id_and_building_id"
    t.index ["firm_id", "listing_for"], name: "index_properties_on_firm_id_and_listing_for"
    t.index ["firm_id", "status"], name: "index_properties_on_firm_id_and_status"
    t.index ["firm_id"], name: "index_properties_on_firm_id"
    t.index ["typology_id"], name: "index_properties_on_typology_id"
    t.check_constraint "floor_band IS NULL OR (floor_band::text = ANY (ARRAY['lower'::character varying::text, 'middle'::character varying::text, 'higher'::character varying::text]))", name: "properties_floor_band_check"
    t.check_constraint "listing_for::text = ANY (ARRAY['sale'::character varying::text, 'rent'::character varying::text])", name: "properties_listing_for_check"
    t.check_constraint "price >= 0", name: "properties_price_check"
    t.check_constraint "status::text = ANY (ARRAY['available'::character varying::text, 'under_offer'::character varying::text, 'closed'::character varying::text])", name: "properties_status_check"
  end

  create_table "property_types", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.string "code", null: false
    t.integer "sort_order", default: 0, null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_property_types_on_code", unique: true
  end

  create_table "subscriptions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "firm_id", null: false
    t.uuid "plan_id", null: false
    t.string "status", default: "active", null: false
    t.date "current_period_start", null: false
    t.date "current_period_end", null: false
    t.bigint "amount", default: 0, null: false
    t.datetime "trial_ends_at"
    t.datetime "cancelled_at"
    t.string "cancel_reason"
    t.uuid "created_by_admin_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_admin_id"], name: "index_subscriptions_on_created_by_admin_id"
    t.index ["firm_id"], name: "index_subscriptions_on_firm_id"
    t.index ["firm_id"], name: "index_subscriptions_one_live_per_firm", unique: true, where: "((status)::text = ANY (ARRAY[('trialing'::character varying)::text, ('active'::character varying)::text]))"
    t.index ["plan_id"], name: "index_subscriptions_on_plan_id"
    t.index ["status", "current_period_end"], name: "index_subscriptions_on_status_and_current_period_end"
    t.check_constraint "current_period_end >= current_period_start", name: "subscriptions_period_check"
    t.check_constraint "status::text = ANY (ARRAY['trialing'::character varying::text, 'active'::character varying::text, 'past_due'::character varying::text, 'lapsed'::character varying::text, 'cancelled'::character varying::text])", name: "subscriptions_status_check"
  end

  create_table "typologies", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.string "code", null: false
    t.decimal "bedrooms", precision: 3, scale: 1
    t.integer "sort_order", default: 0, null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_typologies_on_code", unique: true
  end

  create_table "users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "firm_id", null: false
    t.string "name", null: false
    t.string "email"
    t.string "mobile", null: false
    t.string "role", default: "agent", null: false
    t.string "status", default: "active", null: false
    t.string "rera_number"
    t.string "notification_mode", default: "all", null: false
    t.datetime "last_seen_at"
    t.integer "failed_otp_attempts", default: 0, null: false
    t.datetime "otp_locked_until"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true, where: "(email IS NOT NULL)"
    t.index ["firm_id", "status"], name: "index_users_on_firm_id_and_status"
    t.index ["firm_id"], name: "index_users_on_firm_id"
    t.index ["firm_id"], name: "index_users_one_super_admin_per_firm", unique: true, where: "((role)::text = 'super_admin'::text)"
    t.index ["mobile"], name: "index_users_on_mobile", unique: true
    t.check_constraint "role::text = ANY (ARRAY['super_admin'::character varying::text, 'manager'::character varying::text, 'agent'::character varying::text])", name: "users_role_check"
    t.check_constraint "status::text = ANY (ARRAY['active'::character varying::text, 'disabled'::character varying::text])", name: "users_status_check"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "admin_sessions", "admin_users"
  add_foreign_key "audit_events", "firms"
  add_foreign_key "auth_sessions", "firms"
  add_foreign_key "auth_sessions", "users"
  add_foreign_key "booking_documents", "bookings"
  add_foreign_key "booking_documents", "firms"
  add_foreign_key "booking_documents", "users", column: "uploaded_by_user_id", on_delete: :nullify
  add_foreign_key "bookings", "firms"
  add_foreign_key "bookings", "leads"
  add_foreign_key "bookings", "projects"
  add_foreign_key "bookings", "users", column: "created_by_user_id", on_delete: :nullify
  add_foreign_key "builders", "firms"
  add_foreign_key "buildings", "cities"
  add_foreign_key "buildings", "firms"
  add_foreign_key "buildings", "localities"
  add_foreign_key "collections", "bookings"
  add_foreign_key "collections", "firms"
  add_foreign_key "collections", "invoices"
  add_foreign_key "contact_channels", "firms"
  add_foreign_key "contact_channels", "users", column: "verified_by_user_id"
  add_foreign_key "firm_bank_accounts", "firms"
  add_foreign_key "firms", "cities"
  add_foreign_key "firms", "localities"
  add_foreign_key "invoices", "bookings"
  add_foreign_key "invoices", "firms"
  add_foreign_key "lead_activities", "firms"
  add_foreign_key "lead_activities", "leads"
  add_foreign_key "lead_activities", "users", on_delete: :nullify
  add_foreign_key "lead_status_changes", "firms"
  add_foreign_key "lead_status_changes", "lead_statuses", column: "from_status_id"
  add_foreign_key "lead_status_changes", "lead_statuses", column: "to_status_id"
  add_foreign_key "lead_status_changes", "leads"
  add_foreign_key "lead_status_changes", "users", on_delete: :nullify
  add_foreign_key "lead_typologies", "leads"
  add_foreign_key "lead_typologies", "typologies"
  add_foreign_key "leads", "firms"
  add_foreign_key "leads", "lead_sources"
  add_foreign_key "leads", "lead_statuses"
  add_foreign_key "leads", "property_types"
  add_foreign_key "leads", "users", column: "assigned_user_id", on_delete: :nullify
  add_foreign_key "localities", "cities"
  add_foreign_key "one_time_codes", "contact_channels"
  add_foreign_key "one_time_codes", "users"
  add_foreign_key "project_typologies", "projects"
  add_foreign_key "project_typologies", "typologies"
  add_foreign_key "projects", "builders"
  add_foreign_key "projects", "cities"
  add_foreign_key "projects", "firms"
  add_foreign_key "projects", "localities"
  add_foreign_key "properties", "buildings"
  add_foreign_key "properties", "firms"
  add_foreign_key "properties", "typologies"
  add_foreign_key "subscriptions", "admin_users", column: "created_by_admin_id"
  add_foreign_key "subscriptions", "firms"
  add_foreign_key "subscriptions", "plans"
  add_foreign_key "users", "firms"
end
