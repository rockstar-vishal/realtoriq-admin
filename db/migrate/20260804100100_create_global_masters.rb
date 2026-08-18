# frozen_string_literal: true

# The platform-owned reference tables. These carry no firm_id — every firm sees
# the same cities, builders and typologies, and ops maintain them from the admin
# panel. Buildings are deliberately NOT here: those are firm-owned, because one
# broker's typo shouldn't pollute every other broker's dropdown.
class CreateGlobalMasters < ActiveRecord::Migration[8.0]
  def change
    create_table :cities, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :name, null: false
      t.string :state, null: false
      t.string :country_code, null: false, default: "IN"
      t.string :slug, null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :cities, :slug, unique: true
    add_index :cities, [ :name, :state ], unique: true

    create_table :localities, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :city, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.string :pincode
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :localities, [ :city_id, :name ], unique: true

    create_table :builders, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.string :website
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :builders, :slug, unique: true

    # 1 RK, 1 BHK, 2.5 BHK, Villa, Penthouse … `bedrooms` is decimal because
    # half-configurations (1.5 BHK, 2.5 BHK) are normal in this market, and it
    # is what budget matching sorts on.
    create_table :typologies, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :name, null: false
      t.string :code, null: false
      t.decimal :bedrooms, precision: 3, scale: 1
      t.integer :sort_order, null: false, default: 0
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :typologies, :code, unique: true

    create_table :lead_sources, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :name, null: false
      t.string :code, null: false
      t.string :category, null: false, default: "other"
      t.integer :sort_order, null: false, default: 0
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :lead_sources, :code, unique: true

    # is_dead / is_booked are what make the dead-leads and bookings reports
    # computable without hardcoding status names in SQL.
    create_table :lead_statuses, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :name, null: false
      t.string :code, null: false
      t.string :color
      t.integer :sort_order, null: false, default: 0
      t.boolean :is_dead, null: false, default: false
      t.boolean :is_booked, null: false, default: false
      t.boolean :is_terminal, null: false, default: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :lead_statuses, :code, unique: true

    create_table :property_types, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :name, null: false
      t.string :code, null: false
      t.integer :sort_order, null: false, default: 0
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :property_types, :code, unique: true
  end
end
