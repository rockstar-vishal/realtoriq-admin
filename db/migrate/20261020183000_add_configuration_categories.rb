# frozen_string_literal: true

# Category lives on the configuration master. Leads also store the category
# they were filed under, so one mobile can have a residential sale and a
# commercial sale open together. The old lead index is replaced in this
# migration, remove-then-add, and project rows may repeat a configuration
# when the label differs.
class AddConfigurationCategories < ActiveRecord::Migration[8.0]
  CATEGORIES = "('residential', 'commercial', 'land')"
  AREA_UNITS = "('sqft', 'sqyd', 'sqm', 'guntha', 'acre', 'hectare')"

  def up
    change_table :typologies, bulk: true do |t|
      t.string :category, null: false, default: "residential"
      t.boolean :needs_review, null: false, default: false
      t.datetime :category_confirmed_at
    end
    add_reference :typologies, :merged_into, type: :uuid, foreign_key: { to_table: :typologies }
    add_index :typologies, [ :category, :sort_order ]
    add_check_constraint :typologies, "category IN #{CATEGORIES}", name: "typologies_category_check"

    create_table :configuration_aliases, id: :uuid do |t|
      t.string :key, null: false
      t.references :typology, type: :uuid, null: false, foreign_key: true
      t.string :source, null: false
      t.references :created_by_admin, type: :uuid, foreign_key: { to_table: :admin_users }
      t.timestamps
    end
    add_index :configuration_aliases, :key, unique: true
    add_check_constraint :configuration_aliases,
      "source IN ('merge', 'review', 'seed')",
      name: "configuration_aliases_source_check"

    change_table :properties, bulk: true do |t|
      t.decimal :area_value, precision: 14, scale: 4
      t.string :area_unit, null: false, default: "sqft"
      t.jsonb :details, null: false, default: {}
      t.boolean :pre_leased, null: false, default: false
    end
    add_check_constraint :properties, "area_unit IN #{AREA_UNITS}", name: "properties_area_unit_check"

    change_table :leads, bulk: true do |t|
      t.string :category, null: false, default: "residential"
      t.decimal :area_min_value, precision: 14, scale: 4
      t.decimal :area_max_value, precision: 14, scale: 4
      t.string :area_unit, null: false, default: "sqft"
      t.integer :area_min_sqft
      t.integer :area_max_sqft
      t.boolean :prefers_pre_leased, null: false, default: false
    end
    add_check_constraint :leads, "category IN #{CATEGORIES}", name: "leads_category_check"
    add_check_constraint :leads, "area_unit IN #{AREA_UNITS}", name: "leads_area_unit_check"
    add_check_constraint :leads,
      "area_max_sqft IS NULL OR area_min_sqft IS NULL OR area_max_sqft >= area_min_sqft",
      name: "leads_area_range_check"

    remove_index :leads, name: "index_leads_on_firm_type_and_open_identity"
    add_index :leads, [ :firm_id, :transaction_type, :category, :open_identity ],
      unique: true,
      where: "open_identity IS NOT NULL",
      name: "index_leads_on_firm_type_category_open_identity"

    change_table :project_typologies, bulk: true do |t|
      t.string :label, limit: 60
      t.decimal :area_value, precision: 14, scale: 4
      t.string :area_unit, null: false, default: "sqft"
      t.boolean :needs_review, null: false, default: false
    end
    add_check_constraint :project_typologies, "area_unit IN #{AREA_UNITS}", name: "project_typologies_area_unit_check"
    remove_index :project_typologies, name: "index_project_typologies_on_project_id_and_typology_id"
    add_index :project_typologies,
      "project_id, typology_id, lower(COALESCE(label, ''))",
      unique: true,
      name: "index_project_typologies_on_project_typology_and_label"

    add_column :facebook_lead_forms, :category, :string
    add_check_constraint :facebook_lead_forms,
      "category IS NULL OR category IN #{CATEGORIES}",
      name: "facebook_lead_forms_category_check"
  end

  def down
    remove_check_constraint :facebook_lead_forms, name: "facebook_lead_forms_category_check"
    remove_column :facebook_lead_forms, :category

    remove_index :project_typologies, name: "index_project_typologies_on_project_typology_and_label"
    add_index :project_typologies, [ :project_id, :typology_id ],
      unique: true,
      name: "index_project_typologies_on_project_id_and_typology_id"
    remove_check_constraint :project_typologies, name: "project_typologies_area_unit_check"
    change_table :project_typologies, bulk: true do |t|
      t.remove :label, :area_value, :area_unit, :needs_review
    end

    remove_index :leads, name: "index_leads_on_firm_type_category_open_identity"
    add_index :leads, [ :firm_id, :transaction_type, :open_identity ],
      unique: true,
      where: "open_identity IS NOT NULL",
      name: "index_leads_on_firm_type_and_open_identity"
    remove_check_constraint :leads, name: "leads_area_range_check"
    remove_check_constraint :leads, name: "leads_area_unit_check"
    remove_check_constraint :leads, name: "leads_category_check"
    change_table :leads, bulk: true do |t|
      t.remove :category, :area_min_value, :area_max_value, :area_unit,
        :area_min_sqft, :area_max_sqft, :prefers_pre_leased
    end

    remove_check_constraint :properties, name: "properties_area_unit_check"
    change_table :properties, bulk: true do |t|
      t.remove :area_value, :area_unit, :details, :pre_leased
    end

    drop_table :configuration_aliases

    remove_check_constraint :typologies, name: "typologies_category_check"
    remove_index :typologies, [ :category, :sort_order ]
    remove_reference :typologies, :merged_into, type: :uuid, foreign_key: { to_table: :typologies }
    change_table :typologies, bulk: true do |t|
      t.remove :category, :needs_review, :category_confirmed_at
    end
  end
end
