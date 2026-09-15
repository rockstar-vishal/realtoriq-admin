# frozen_string_literal: true

# Product-locked rules for the next frontend slice:
# - one lead per (firm, mobile, transaction_type)
# - live bookings unique on (project, unit_no); unit required when a project is set
# - My Projects / catalog names unique case-insensitively within each source
# - catalog external_ref unique per firm (the old index was global)
# - properties remember who sourced them
# - lead ↔ project / property mappings
class AddLeadInventoryAndBookingRules < ActiveRecord::Migration[8.0]
  def change
    remove_index :leads, column: [ :firm_id, :mobile ]
    add_index :leads, [ :firm_id, :mobile, :transaction_type ],
      unique: true, name: "index_leads_on_firm_mobile_transaction_type"

    add_index :bookings, [ :project_id, :unit_no ],
      unique: true,
      where: "status = 'live' AND project_id IS NOT NULL AND unit_no IS NOT NULL",
      name: "index_bookings_on_live_project_unit"

    add_reference :properties, :created_by_user,
      foreign_key: { to_table: :users, on_delete: :nullify }, type: :uuid

    create_table :lead_projects, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: true, type: :uuid
      t.references :lead, null: false, foreign_key: true, type: :uuid
      t.references :project, null: false, foreign_key: true, type: :uuid
      t.timestamps
    end
    add_index :lead_projects, [ :lead_id, :project_id ], unique: true

    create_table :lead_properties, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: true, type: :uuid
      t.references :lead, null: false, foreign_key: true, type: :uuid
      t.references :property, null: false, foreign_key: true, type: :uuid
      t.timestamps
    end
    add_index :lead_properties, [ :lead_id, :property_id ], unique: true

    reversible do |dir|
      dir.up do
        execute <<~SQL.squish
          CREATE UNIQUE INDEX index_projects_on_firm_own_lower_name
          ON projects (firm_id, LOWER(name))
          WHERE source = 'own'
        SQL
        execute <<~SQL.squish
          CREATE UNIQUE INDEX index_projects_on_firm_catalog_lower_name
          ON projects (firm_id, LOWER(name))
          WHERE source = 'catalog'
        SQL
        remove_index :projects, name: "index_projects_on_source_and_external_ref"
        add_index :projects, [ :firm_id, :source, :external_ref ],
          unique: true,
          where: "external_ref IS NOT NULL",
          name: "index_projects_on_firm_source_and_external_ref"
      end
      dir.down do
        remove_index :projects, name: "index_projects_on_firm_source_and_external_ref"
        add_index :projects, [ :source, :external_ref ],
          unique: true,
          where: "external_ref IS NOT NULL",
          name: "index_projects_on_source_and_external_ref"
        execute "DROP INDEX IF EXISTS index_projects_on_firm_own_lower_name"
        execute "DROP INDEX IF EXISTS index_projects_on_firm_catalog_lower_name"
      end
    end
  end
end
