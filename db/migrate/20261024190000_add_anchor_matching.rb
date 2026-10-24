# frozen_string_literal: true

# One row in anchor_matchings means anchor matching is on. The table stays
# empty until matches:anchor_enable, so a deploy does not change match lists.
class AddAnchorMatching < ActiveRecord::Migration[8.0]
  def up
    create_table :anchor_matchings, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.datetime :enabled_at, null: false
      t.integer :radius_m, null: false, default: 6000
      t.timestamps
    end
    add_check_constraint :anchor_matchings, "radius_m BETWEEN 1000 AND 6000",
      name: "anchor_matchings_radius_m_check"

    change_table :leads, bulk: true do |t|
      t.string :near_label
      t.string :near_address
      t.decimal :near_lat, precision: 10, scale: 7
      t.decimal :near_lng, precision: 10, scale: 7
      t.string :near_place_id
    end

    add_index :projects, [ :lat, :lng ],
      name: "index_projects_on_pin",
      where: "lat IS NOT NULL AND lng IS NOT NULL"
    add_index :properties, [ :lat, :lng ],
      name: "index_properties_on_pin",
      where: "lat IS NOT NULL AND lng IS NOT NULL"
    add_index :leads, [ :near_lat, :near_lng ],
      name: "index_leads_on_near_pin",
      where: "near_lat IS NOT NULL AND near_lng IS NOT NULL"
  end

  def down
    remove_index :leads, name: "index_leads_on_near_pin"
    remove_index :properties, name: "index_properties_on_pin"
    remove_index :projects, name: "index_projects_on_pin"
    change_table :leads, bulk: true do |t|
      t.remove :near_label, :near_address, :near_lat, :near_lng, :near_place_id
    end
    drop_table :anchor_matchings
  end
end
