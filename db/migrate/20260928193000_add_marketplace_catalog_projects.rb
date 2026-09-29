# frozen_string_literal: true

# Marketplace projects are one catalog row per turbo project code, shared by
# every firm. firm_id stays null on those rows. Own projects are unchanged.
class AddMarketplaceCatalogProjects < ActiveRecord::Migration[8.0]
  def change
    change_column_null :projects, :firm_id, true

    change_table :projects, bulk: true do |t|
      t.string :rm_name
      t.string :rm_contact
      t.string :company_code
      t.datetime :turbo_pushed_at
    end

    add_index :projects, :external_ref,
      unique: true,
      where: "source = 'catalog' AND firm_id IS NULL AND external_ref IS NOT NULL",
      name: "index_projects_on_global_catalog_external_ref"
  end
end
