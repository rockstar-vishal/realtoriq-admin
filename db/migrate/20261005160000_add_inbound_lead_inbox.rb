# frozen_string_literal: true

# Brokers hand a website one key and two URLs. Portal listing codes live on
# the project and the property, off the main forms, so a 99acres id can find
# the listing without lengthening those screens.
class AddInboundLeadInbox < ActiveRecord::Migration[8.0]
  PORTAL_COLUMNS = %w[portal_99acres_code portal_magicbricks_code portal_housing_code].freeze

  def up
    PORTAL_COLUMNS.each do |column|
      add_column :projects, column, :string
      add_column :properties, column, :string
      add_index :projects, "firm_id, lower(#{column})",
        unique: true,
        where: "#{column} IS NOT NULL AND firm_id IS NOT NULL",
        name: "index_projects_firm_#{column}"
      add_index :properties, "firm_id, lower(#{column})",
        unique: true,
        where: "#{column} IS NOT NULL",
        name: "index_properties_firm_#{column}"
    end

    create_table :inbound_credentials, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: true, type: :uuid, index: { unique: true }
      t.string :token_digest, null: false
      t.text :token, null: false
      t.timestamps
    end
    add_index :inbound_credentials, :token_digest, unique: true

    create_table :inbound_enquiries, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: true, type: :uuid
      t.string :channel, null: false
      t.string :external_id, null: false
      t.references :lead, null: false, foreign_key: true, type: :uuid
      t.timestamps
    end
    add_index :inbound_enquiries, %i[firm_id channel external_id],
      unique: true, name: "index_inbound_enquiries_on_firm_channel_and_external_id"
    add_check_constraint :inbound_enquiries,
      "channel IN ('99acres', 'magicbricks', 'housing', 'general')",
      name: "inbound_enquiries_channel_check"

    remove_check_constraint :notifications, name: "notifications_kind_check"
    add_check_constraint :notifications,
      "kind IN ('followup_due', 'test', 'training_published', 'marketplace_enquiry', 'inbound_enquiry')",
      name: "notifications_kind_check"

    [
      [ "Portal — Magicbricks", "portal" ],
      [ "Website", "other" ]
    ].each do |name, category|
      next if LeadSource.exists?(name:)

      LeadSource.create!(
        name:, category:, sort_order: LeadSource.maximum(:sort_order).to_i + 1
      )
    end
  end

  def down
    LeadSource.where(name: [ "Portal — Magicbricks", "Website" ]).delete_all

    remove_check_constraint :notifications, name: "notifications_kind_check"
    add_check_constraint :notifications,
      "kind IN ('followup_due', 'test', 'training_published', 'marketplace_enquiry')",
      name: "notifications_kind_check"

    drop_table :inbound_enquiries
    drop_table :inbound_credentials

    PORTAL_COLUMNS.each do |column|
      remove_column :projects, column
      remove_column :properties, column
    end
  end
end
