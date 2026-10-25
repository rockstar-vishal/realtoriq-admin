# frozen_string_literal: true

# Properties have owned their location since the location move. The buildings
# table was only the old grouping. Down recreates the empty table and column.
# The rows are not restored; the backup is the way back.
class DropBuildings < ActiveRecord::Migration[8.0]
  def up
    remove_foreign_key :properties, :buildings
    remove_index :properties, name: "index_properties_on_firm_id_and_building_id"
    remove_index :properties, name: "index_properties_on_building_id"
    remove_column :properties, :building_id
    drop_table :buildings
  end

  def down
    create_table :buildings, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :firm_id, null: false
      t.string :name, null: false
      t.uuid :city_id, null: false
      t.uuid :locality_id, null: false
      t.string :address
      t.decimal :lat, precision: 10, scale: 7
      t.decimal :lng, precision: 10, scale: 7
      t.string :google_place_id
      t.boolean :has_pool, default: false, null: false
      t.boolean :has_gym, default: false, null: false
      t.timestamps
    end
    add_index :buildings, [ :city_id, :lat, :lng ],
      name: "index_buildings_on_city_and_pin",
      where: "lat IS NOT NULL AND lng IS NOT NULL"
    add_index :buildings, :city_id
    add_index :buildings, [ :firm_id, :city_id ]
    add_index :buildings, [ :firm_id, :name, :locality_id ], unique: true
    add_index :buildings, :firm_id
    add_index :buildings, :locality_id
    add_foreign_key :buildings, :cities
    add_foreign_key :buildings, :firms
    add_foreign_key :buildings, :localities

    add_reference :properties, :building, type: :uuid, foreign_key: true
    add_index :properties, [ :firm_id, :building_id ]
  end
end
