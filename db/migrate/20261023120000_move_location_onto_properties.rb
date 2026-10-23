# frozen_string_literal: true

# A property owns the place it is in. The building row stays only as the old
# grouping (building_id, now nullable) until the cleanup release.
class MoveLocationOntoProperties < ActiveRecord::Migration[8.0]
  # Specs re-run this after wiping a row, so the copy lives in one place.
  BACKFILL = <<~SQL.squish
    UPDATE properties
    SET building_name = buildings.name,
        city_id = buildings.city_id,
        locality_id = buildings.locality_id,
        address = buildings.address,
        lat = buildings.lat,
        lng = buildings.lng,
        google_place_id = buildings.google_place_id,
        has_pool = buildings.has_pool,
        has_gym = buildings.has_gym
    FROM buildings
    WHERE properties.building_id = buildings.id
  SQL

  def up
    add_column :properties, :building_name, :string
    add_column :properties, :city_id, :uuid
    add_column :properties, :locality_id, :uuid
    add_column :properties, :address, :string
    add_column :properties, :lat, :decimal, precision: 10, scale: 7
    add_column :properties, :lng, :decimal, precision: 10, scale: 7
    add_column :properties, :google_place_id, :string
    add_column :properties, :has_pool, :boolean, default: false, null: false
    add_column :properties, :has_gym, :boolean, default: false, null: false

    execute BACKFILL

    change_column_null :properties, :building_name, false
    change_column_null :properties, :city_id, false
    change_column_null :properties, :locality_id, false
    change_column_null :properties, :building_id, true

    add_index :properties, %i[firm_id locality_id], name: "index_properties_on_firm_id_and_locality_id"
    add_index :properties, :locality_id
    add_index :properties, %i[city_id lat lng],
      name: "index_properties_on_city_and_pin",
      where: "lat IS NOT NULL AND lng IS NOT NULL"
    add_foreign_key :properties, :cities
    add_foreign_key :properties, :localities
  end

  # Structure only. Rows created after this migration keep their location;
  # building columns are not filled back in.
  def down
    remove_foreign_key :properties, :localities
    remove_foreign_key :properties, :cities
    remove_index :properties, name: "index_properties_on_city_and_pin"
    remove_index :properties, :locality_id
    remove_index :properties, name: "index_properties_on_firm_id_and_locality_id"

    change_column_null :properties, :building_id, false

    remove_column :properties, :has_gym
    remove_column :properties, :has_pool
    remove_column :properties, :google_place_id
    remove_column :properties, :lng
    remove_column :properties, :lat
    remove_column :properties, :address
    remove_column :properties, :locality_id
    remove_column :properties, :city_id
    remove_column :properties, :building_name
  end
end
