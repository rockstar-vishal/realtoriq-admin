# frozen_string_literal: true

# Centers for nearby matching. Blank until a geocode or an admin edit fills
# them. A center outside Maharashtra is rejected by the model, so a swapped
# latitude and longitude cannot become a neighbor.
class AddCoordinatesToLocalities < ActiveRecord::Migration[8.0]
  def change
    change_table :localities, bulk: true do |t|
      t.decimal :lat, precision: 10, scale: 7
      t.decimal :lng, precision: 10, scale: 7
    end
  end
end
