# frozen_string_literal: true

# A completed outing with a lead. Sites are optional and must already be
# mapped. first_visit_at is replaced by "has at least one lead_visits row".
class CreateLeadVisits < ActiveRecord::Migration[8.0]
  def change
    create_table :lead_visits, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: true, type: :uuid
      t.references :lead, null: false, foreign_key: { on_delete: :restrict }, type: :uuid
      t.references :user, foreign_key: { on_delete: :nullify }, type: :uuid
      t.datetime :visited_at, null: false
      t.text :notes
      t.timestamps
    end
    add_index :lead_visits, [ :lead_id, :visited_at ]

    create_table :lead_visit_projects, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: true, type: :uuid
      t.references :lead_visit, null: false, foreign_key: { on_delete: :restrict }, type: :uuid
      t.references :project, null: false, foreign_key: { on_delete: :restrict }, type: :uuid
      t.timestamps
    end
    add_index :lead_visit_projects, [ :lead_visit_id, :project_id ], unique: true

    create_table :lead_visit_properties, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: true, type: :uuid
      t.references :lead_visit, null: false, foreign_key: { on_delete: :restrict }, type: :uuid
      t.references :property, null: false, foreign_key: { on_delete: :restrict }, type: :uuid
      t.timestamps
    end
    add_index :lead_visit_properties, [ :lead_visit_id, :property_id ], unique: true

    remove_column :leads, :first_visit_at, :datetime
  end
end
