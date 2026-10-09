# frozen_string_literal: true

# Pin boxes filter projects and buildings by city and coordinate range.
class IndexListingCoordinates < ActiveRecord::Migration[8.0]
  def change
    add_index :projects, [ :city_id, :lat, :lng ],
      name: "index_projects_on_city_and_pin",
      where: "lat IS NOT NULL AND lng IS NOT NULL"
    add_index :buildings, [ :city_id, :lat, :lng ],
      name: "index_buildings_on_city_and_pin",
      where: "lat IS NOT NULL AND lng IS NOT NULL"
  end
end
