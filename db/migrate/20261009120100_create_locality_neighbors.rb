# frozen_string_literal: true

# Same-city locality pairs whose centers are within 6 km. Rebuilt when a
# center is saved. Matching reads this table; it does not measure the city
# on each request. Stored in both directions so a lookup is one indexed read.
class CreateLocalityNeighbors < ActiveRecord::Migration[8.0]
  def change
    create_table :locality_neighbors, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :locality, null: false, foreign_key: true, type: :uuid
      t.uuid :neighbor_locality_id, null: false
      t.integer :distance_m, null: false
      t.timestamps
    end

    add_foreign_key :locality_neighbors, :localities, column: :neighbor_locality_id
    add_index :locality_neighbors, %i[locality_id neighbor_locality_id],
      unique: true, name: "index_locality_neighbors_on_pair"
    add_index :locality_neighbors, :neighbor_locality_id
  end
end
