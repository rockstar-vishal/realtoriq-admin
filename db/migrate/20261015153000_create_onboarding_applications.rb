# frozen_string_literal: true

# One row per submitted registration. There is no draft: the row appears only
# when Submit succeeds, together with the pending firm.
class CreateOnboardingApplications < ActiveRecord::Migration[8.0]
  def change
    create_table :onboarding_applications, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: { on_delete: :restrict }, type: :uuid, index: { unique: true }
      t.string :reference, null: false
      t.string :status, null: false, default: "submitted"

      t.string :applicant_name, null: false
      t.string :applicant_designation, null: false
      t.string :mobile, null: false
      t.string :whatsapp, null: false
      t.string :email, null: false
      t.datetime :mobile_verified_at, null: false
      t.datetime :whatsapp_verified_at
      t.datetime :email_verified_at, null: false

      t.string :entity_type, null: false
      t.string :firm_name, null: false
      t.string :legal_name, null: false
      t.string :pan
      t.string :gst_number
      t.string :team_size

      t.boolean :rera_registered, null: false
      t.string :rera_number
      t.date :rera_valid_till
      t.datetime :rera_declared_at

      t.string :address_line1, null: false
      t.string :address_line2
      t.references :city, null: false, foreign_key: true, type: :uuid
      t.references :locality, null: false, foreign_key: true, type: :uuid
      t.string :pincode, null: false
      t.uuid :extra_locality_ids, array: true, null: false, default: []

      t.datetime :submitted_at, null: false
      t.string :submit_ip
      t.string :submit_user_agent
      t.string :created_ip
      t.datetime :captcha_verified_at, null: false

      t.datetime :reviewed_at
      t.references :reviewed_by_admin, foreign_key: { to_table: :admin_users }, type: :uuid
      t.text :rejection_reason
      t.text :internal_notes

      t.timestamps
    end

    add_index :onboarding_applications, :reference, unique: true
    add_index :onboarding_applications, :status
    add_index :onboarding_applications, :pan
    add_index :onboarding_applications, :gst_number
    add_index :onboarding_applications, :rera_number
    add_index :onboarding_applications, :mobile,
      unique: true,
      where: "status = 'submitted'",
      name: "index_onboarding_applications_one_submitted_mobile"
    add_index :onboarding_applications, "lower(email)",
      unique: true,
      where: "status = 'submitted'",
      name: "index_onboarding_applications_one_submitted_email"

    add_check_constraint :onboarding_applications,
      "status IN ('submitted', 'rejected', 'lapsed')",
      name: "onboarding_applications_status_check"
    add_check_constraint :onboarding_applications,
      "entity_type IN ('individual', 'proprietorship', 'partnership', 'llp', 'private_limited', 'public_limited', 'other')",
      name: "onboarding_applications_entity_type_check"
    add_check_constraint :onboarding_applications,
      "team_size IS NULL OR team_size IN ('just_me', '2_5', '6_20', '21_plus')",
      name: "onboarding_applications_team_size_check"
  end
end
