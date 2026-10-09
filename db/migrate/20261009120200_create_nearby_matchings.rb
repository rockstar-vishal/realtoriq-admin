# frozen_string_literal: true

# One row means nearby matching is on. The table stays empty until
# `bin/rails matches:nearby_enable`, so a half-finished coordinate backfill
# cannot change a digest or send a notification.
class CreateNearbyMatchings < ActiveRecord::Migration[8.0]
  def change
    create_table :nearby_matchings, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.datetime :enabled_at, null: false
      t.timestamps
    end
  end
end
