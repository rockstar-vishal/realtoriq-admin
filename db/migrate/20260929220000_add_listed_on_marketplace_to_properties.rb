# frozen_string_literal: true

# A broker's resale or rental listing can be offered to other firms. Existing
# rows start shared; the broker turns the switch off to keep a listing private.
class AddListedOnMarketplaceToProperties < ActiveRecord::Migration[8.0]
  def change
    add_column :properties, :listed_on_marketplace, :boolean, null: false, default: true
    add_index :properties, :listed_on_marketplace,
      where: "listed_on_marketplace = TRUE AND status = 'available'",
      name: "index_properties_on_available_marketplace"
  end
end