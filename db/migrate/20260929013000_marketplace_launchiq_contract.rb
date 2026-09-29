# frozen_string_literal: true

# The fields LaunchIQ now sends, and the rows RealtorIQ needs to honour them:
# a withdrawn mapping, one stored enquiry per form, a pass that can sit pending
# until LaunchIQ answers, and the marketplace enquiry notification.
class MarketplaceLaunchiqContract < ActiveRecord::Migration[8.0]
  def up
    add_column :lead_projects, :withdrawn_at, :datetime

    create_table :marketplace_enquiries, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: true, type: :uuid
      t.references :project_share_link, null: false, foreign_key: true, type: :uuid
      t.references :lead, foreign_key: true, type: :uuid
      t.string :enquiry_id, null: false
      t.string :outcome
      t.datetime :submitted_at
      t.timestamps
    end
    add_index :marketplace_enquiries, :enquiry_id, unique: true,
      name: "index_marketplace_enquiries_on_enquiry_id"

    change_column_null :lead_visit_passes, :pass_code, true
    remove_index :lead_visit_passes, name: "index_lead_visit_passes_on_pass_code"
    add_index :lead_visit_passes, :pass_code, unique: true, where: "pass_code IS NOT NULL",
      name: "index_lead_visit_passes_on_pass_code"
    add_index :lead_visit_passes, [ :lead_id, :project_id ],
      unique: true,
      where: "turbo_status IN ('pending', 'unused', 'used')",
      name: "index_lead_visit_passes_on_open_lead_and_project"
    add_column :lead_visit_passes, :pass_url, :string
    add_column :lead_visit_passes, :address, :string
    add_column :lead_visit_passes, :rm_name, :string
    add_column :lead_visit_passes, :rm_contact, :string
    add_column :lead_visit_passes, :status_message, :text

    remove_check_constraint :notifications, name: "notifications_kind_check"
    add_check_constraint :notifications,
      "kind IN ('followup_due', 'test', 'training_published', 'marketplace_enquiry')",
      name: "notifications_kind_check"

    unless LeadSource.exists?(name: "Builder Microsite")
      LeadSource.create!(
        name: "Builder Microsite",
        category: "other",
        sort_order: LeadSource.maximum(:sort_order).to_i + 1
      )
    end
  end

  def down
    LeadSource.find_by(name: "Builder Microsite")&.destroy

    remove_check_constraint :notifications, name: "notifications_kind_check"
    add_check_constraint :notifications,
      "kind IN ('followup_due', 'test', 'training_published')",
      name: "notifications_kind_check"

    remove_column :lead_visit_passes, :status_message
    remove_column :lead_visit_passes, :rm_contact
    remove_column :lead_visit_passes, :rm_name
    remove_column :lead_visit_passes, :address
    remove_column :lead_visit_passes, :pass_url
    remove_index :lead_visit_passes, name: "index_lead_visit_passes_on_open_lead_and_project"
    remove_index :lead_visit_passes, name: "index_lead_visit_passes_on_pass_code"
    add_index :lead_visit_passes, :pass_code, unique: true, name: "index_lead_visit_passes_on_pass_code"
    change_column_null :lead_visit_passes, :pass_code, false

    drop_table :marketplace_enquiries
    remove_column :lead_projects, :withdrawn_at
  end
end
