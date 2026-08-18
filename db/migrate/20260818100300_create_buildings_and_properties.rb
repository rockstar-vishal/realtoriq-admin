# frozen_string_literal: true

# Resale and rental listings, and the buildings they sit in.
#
# Buildings are firm-owned rather than a global master: they are created inline
# from the property form ("Building not listed? Add new"), and one broker's typo
# must not reach every other broker's dropdown.
class CreateBuildingsAndProperties < ActiveRecord::Migration[8.0]
  def change
    create_table :buildings, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: true, type: :uuid

      t.string :name, null: false
      t.references :city, null: false, foreign_key: true, type: :uuid
      t.references :locality, null: false, foreign_key: true, type: :uuid

      t.string  :address
      t.decimal :lat, precision: 10, scale: 7
      t.decimal :lng, precision: 10, scale: 7
      t.string  :google_place_id

      # Amenities live on the building, not the listing — every flat in it
      # shares the same pool.
      t.boolean :has_pool, null: false, default: false
      t.boolean :has_gym, null: false, default: false

      t.timestamps
    end

    add_index :buildings, [ :firm_id, :name, :locality_id ], unique: true
    add_index :buildings, [ :firm_id, :city_id ]

    create_table :properties, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: true, type: :uuid
      t.references :building, null: false, foreign_key: true, type: :uuid
      t.references :typology, null: false, foreign_key: true, type: :uuid

      t.string :listing_for, null: false

      t.string :floor_band

      # Sale price, or monthly rent when listing_for is 'rent'. Whole rupees.
      t.bigint  :price, null: false
      t.integer :carpet_area_sqft

      t.date :available_from
      t.text :description

      # Owner details, negotiating room — the design puts this behind a reveal
      # so it can't appear on a client's screen by accident. It is excluded from
      # every list payload and from the shareable subset; only the detail
      # response carries it.
      t.text :confidential_note

      t.string :status, null: false, default: "available"

      t.timestamps
    end

    add_index :properties, [ :firm_id, :status ]
    add_index :properties, [ :firm_id, :listing_for ]
    add_index :properties, [ :firm_id, :building_id ]

    add_check_constraint :properties, "listing_for IN ('sale', 'rent')",
      name: "properties_listing_for_check"
    add_check_constraint :properties,
      "floor_band IS NULL OR floor_band IN ('lower', 'middle', 'higher')",
      name: "properties_floor_band_check"
    add_check_constraint :properties, "status IN ('available', 'under_offer', 'closed')",
      name: "properties_status_check"
    add_check_constraint :properties, "price >= 0", name: "properties_price_check"
  end
end
