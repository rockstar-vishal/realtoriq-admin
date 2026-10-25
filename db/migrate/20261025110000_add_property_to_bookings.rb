# frozen_string_literal: true

# A resale or rental booking can point at the listing it sold. Existing rows
# stay unlinked: nothing here is backfilled. The partial index is one live
# booking per listing per firm, so two firms can each record a co-broke.
class AddPropertyToBookings < ActiveRecord::Migration[8.0]
  def change
    add_reference :bookings, :property, type: :uuid, index: true, foreign_key: { on_delete: :nullify }
    add_index :bookings, [ :firm_id, :property_id ],
      unique: true,
      where: "status = 'live' AND property_id IS NOT NULL",
      name: "index_bookings_on_live_firm_property"
  end
end
