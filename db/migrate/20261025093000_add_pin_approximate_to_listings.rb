# frozen_string_literal: true

# A demo listing can sit on its locality centre until someone drags the pin.
# The flag is not a real place: matching and map links ignore it.
class AddPinApproximateToListings < ActiveRecord::Migration[8.0]
  def change
    add_column :properties, :pin_approximate, :boolean, null: false, default: false
    add_column :projects, :pin_approximate, :boolean, null: false, default: false
  end
end
