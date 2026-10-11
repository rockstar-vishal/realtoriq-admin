# frozen_string_literal: true

# Public firm sites. Slugs are assigned once and kept when a name changes, so a
# shared link still resolves. on_website and website_enabled default on: the
# existing book is public until a broker turns a listing or the whole site off.
class AddFirmWebsites < ActiveRecord::Migration[8.0]
  WEBSITE_KIND = "kind IN ('followup_due', 'test', 'training_published', " \
    "'marketplace_enquiry', 'inbound_enquiry', 'facebook', 'match_digest', 'website_enquiry')"
  PREVIOUS_KIND = "kind IN ('followup_due', 'test', 'training_published', " \
    "'marketplace_enquiry', 'inbound_enquiry', 'facebook', 'match_digest')"

  def up
    change_table :firms, bulk: true do |t|
      t.text :about
      t.boolean :website_enabled, null: false, default: true
      t.string :website_phone
      t.decimal :lat, precision: 10, scale: 7
      t.decimal :lng, precision: 10, scale: 7
      t.string :google_place_id
    end
    add_check_constraint :firms,
      "(lat IS NULL AND lng IS NULL) OR (lat IS NOT NULL AND lng IS NOT NULL)",
      name: "firms_pin_pair"

    add_column :projects, :slug, :string
    add_column :projects, :on_website, :boolean, null: false, default: true
    add_column :properties, :slug, :string
    add_column :properties, :on_website, :boolean, null: false, default: true

    shorten_firm_slugs
    backfill_project_slugs
    backfill_property_slugs

    change_column_null :properties, :slug, false
    add_index :projects, [ :firm_id, :slug ], unique: true,
      where: "firm_id IS NOT NULL AND slug IS NOT NULL",
      name: "index_projects_on_firm_id_and_slug"
    add_index :properties, [ :firm_id, :slug ], unique: true,
      name: "index_properties_on_firm_id_and_slug"

    remove_check_constraint :notifications, name: "notifications_kind_check"
    add_check_constraint :notifications, WEBSITE_KIND, name: "notifications_kind_check"

    insert_lead_source
  end

  def down
    execute("DELETE FROM notifications WHERE kind = 'website_enquiry'")
    source_id = select_value("SELECT id FROM lead_sources WHERE code = 'broker_website'")
    if source_id
      quoted = connection.quote(source_id)
      execute("UPDATE leads SET lead_source_id = NULL WHERE lead_source_id = #{quoted}")
      execute("DELETE FROM lead_sources WHERE id = #{quoted}")
    end

    remove_check_constraint :notifications, name: "notifications_kind_check"
    add_check_constraint :notifications, PREVIOUS_KIND, name: "notifications_kind_check"

    remove_index :properties, name: "index_properties_on_firm_id_and_slug"
    remove_index :projects, name: "index_projects_on_firm_id_and_slug"
    remove_column :properties, :slug
    remove_column :properties, :on_website
    remove_column :projects, :slug
    remove_column :projects, :on_website
    remove_check_constraint :firms, name: "firms_pin_pair"
    change_table :firms, bulk: true do |t|
      t.remove :about, :website_enabled, :website_phone, :lat, :lng, :google_place_id
    end
  end

  private

  def shorten_firm_slugs
    used = select_values("SELECT slug FROM firms")
    select_rows("SELECT id, slug FROM firms WHERE length(slug) > 60").each do |id, slug|
      base = slug[0, 50].sub(/-\z/, "")
      candidate = base
      n = 2
      while used.include?(candidate)
        candidate = "#{base}-#{n}"
        n += 1
      end
      used.delete(slug)
      used << candidate
      execute("UPDATE firms SET slug = #{connection.quote(candidate)} WHERE id = #{connection.quote(id)}")
    end
  end

  def backfill_project_slugs
    rows = select_rows(<<~SQL.squish)
      SELECT id, firm_id, name FROM projects
      WHERE firm_id IS NOT NULL
      ORDER BY created_at, id
    SQL
    assign_slugs(rows, :projects) { |_id, _firm_id, name| name }
  end

  def backfill_property_slugs
    rows = select_rows(<<~SQL.squish)
      SELECT properties.id, properties.firm_id, typologies.name, localities.name, buildings.name
      FROM properties
      LEFT JOIN typologies ON typologies.id = properties.typology_id
      LEFT JOIN buildings ON buildings.id = properties.building_id
      LEFT JOIN localities ON localities.id = buildings.locality_id
      ORDER BY properties.created_at, properties.id
    SQL
    assign_slugs(rows, :properties) do |_id, _firm_id, typology, locality, building|
      [ typology, locality ].compact_blank.join(" in ").presence || building
    end
  end

  def assign_slugs(rows, table)
    taken = Hash.new { |hash, key| hash[key] = {} }
    rows.each do |row|
      id = row[0]
      firm_id = row[1]
      text = yield(*row)
      slug = Inventory::PublicSlug.mint(text, taken[firm_id])
      execute(<<~SQL.squish)
        UPDATE #{table} SET slug = #{connection.quote(slug)} WHERE id = #{connection.quote(id)}
      SQL
    end
  end

  def insert_lead_source
    return if select_value("SELECT id FROM lead_sources WHERE code = 'broker_website'")

    sort_order = select_value("SELECT COALESCE(MAX(sort_order), -1) + 1 FROM lead_sources").to_i
    execute(<<~SQL.squish)
      INSERT INTO lead_sources (id, name, code, category, sort_order, active, created_at, updated_at)
      VALUES (gen_random_uuid(), 'Broker website', 'broker_website', 'other', #{sort_order}, true, NOW(), NOW())
    SQL
  end
end
