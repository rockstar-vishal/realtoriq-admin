# frozen_string_literal: true

# Preferred localities for a lead. Several are allowed. The row has no firm_id:
# it is only ever reached through a lead, which is already firm-scoped.
class CreateLeadLocalities < ActiveRecord::Migration[8.0]
  def change
    create_table :lead_localities, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :lead, null: false, foreign_key: true, type: :uuid
      t.references :locality, null: false, foreign_key: true, type: :uuid
      t.timestamps
    end

    add_index :lead_localities, [ :lead_id, :locality_id ], unique: true,
      name: "index_lead_localities_on_lead_id_and_locality_id"
  end
end
