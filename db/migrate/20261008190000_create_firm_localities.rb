# frozen_string_literal: true

# Localities a firm works in besides its primary `firms.locality_id`.
# Ops sets these on the firm form. The marketplace rank reads them; the
# broker app does not.
class CreateFirmLocalities < ActiveRecord::Migration[8.0]
  def change
    create_table :firm_localities, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: true, type: :uuid
      t.references :locality, null: false, foreign_key: true, type: :uuid
      t.timestamps
    end

    add_index :firm_localities, [ :firm_id, :locality_id ], unique: true,
      name: "index_firm_localities_on_firm_id_and_locality_id"
  end
end
