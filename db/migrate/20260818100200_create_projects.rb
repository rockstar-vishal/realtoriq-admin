# frozen_string_literal: true

# Developer inventory — new construction a broker sells on commission.
# Distinct from `properties`, which are resale and rental listings.
class CreateProjects < ActiveRecord::Migration[8.0]
  def change
    create_table :projects, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: true, type: :uuid

      t.string :name, null: false
      t.references :builder, null: false, foreign_key: true, type: :uuid
      t.references :city, null: false, foreign_key: true, type: :uuid
      t.references :locality, foreign_key: true, type: :uuid

      t.string  :address
      t.decimal :lat, precision: 10, scale: 7
      t.decimal :lng, precision: 10, scale: 7
      t.string  :google_place_id

      # Whole rupees. The design's field reads "₹ lakh" — that is a client-side
      # unit, converted before it reaches here, like every other amount.
      t.bigint :starting_budget, null: false

      t.date   :possession_on
      # "Ready" and similar, for projects with no dated handover.
      t.string :possession_label

      t.string  :rera_number
      t.decimal :brokerage_percent, precision: 5, scale: 2

      t.string :promo_text
      # Answers the design's open question about the promo countdown — an offer
      # with no end date can't be counted down to.
      t.date   :promo_ends_on

      t.string :status, null: false, default: "active"

      # The seam for the turbo-rails8 opportunities feed. Everything created
      # through this API is "own"; catalog rows will arrive with an external_ref
      # and will make firm_id nullable when that integration lands.
      t.string :source, null: false, default: "own"
      t.string :external_ref

      t.timestamps
    end

    add_index :projects, [ :firm_id, :status ]
    add_index :projects, [ :firm_id, :builder_id ]
    add_index :projects, [ :firm_id, :city_id ]
    add_index :projects, [ :source, :external_ref ], unique: true, where: "external_ref IS NOT NULL"

    add_check_constraint :projects, "source IN ('own', 'catalog')", name: "projects_source_check"
    add_check_constraint :projects, "status IN ('active', 'archived')", name: "projects_status_check"
    add_check_constraint :projects, "starting_budget >= 0", name: "projects_starting_budget_check"

    # One row per typology a project offers. The price and area *bands* the
    # index card shows are min/max across these — derived, never stored, so a
    # band cannot contradict its own rows.
    create_table :project_typologies, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :project, null: false, foreign_key: true, type: :uuid
      t.references :typology, null: false, foreign_key: true, type: :uuid

      t.bigint  :starting_price
      t.integer :starting_carpet_sqft

      t.timestamps
    end

    add_index :project_typologies, [ :project_id, :typology_id ], unique: true
  end
end
