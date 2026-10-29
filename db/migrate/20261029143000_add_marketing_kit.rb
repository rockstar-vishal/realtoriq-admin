# frozen_string_literal: true

class AddMarketingKit < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :rera_registrations, :jsonb, null: false, default: []
    add_column :leads, :web_enquiry, :jsonb, null: false, default: {}

    create_table :project_creatives, id: :uuid do |t|
      t.references :project, type: :uuid, null: false, foreign_key: true
      t.string :external_id, null: false
      t.string :title, null: false
      t.string :kind, null: false
      t.integer :position, null: false, default: 0
      t.string :registration_numbers, array: true, null: false, default: []
      t.string :checksum
      t.integer :page_count
      t.timestamps
      t.index [ :project_id, :external_id ], unique: true
      t.index [ :project_id, :position ]
    end

    create_table :personalised_creatives, id: :uuid do |t|
      t.references :firm, type: :uuid, null: false, foreign_key: true
      t.references :project_creative, type: :uuid, null: false, foreign_key: true
      t.string :fingerprint, null: false
      t.timestamps
      t.index [ :firm_id, :project_creative_id, :fingerprint ],
        unique: true, name: "index_personalised_creatives_on_firm_creative_fingerprint"
    end

    create_table :microsite_kits, id: :uuid do |t|
      t.references :firm, type: :uuid, null: false, foreign_key: true
      t.references :project, type: :uuid, null: false, foreign_key: true
      t.string :fingerprint, null: false
      t.string :status, null: false, default: "preparing"
      t.text :error_message
      t.date :prepared_on
      t.timestamps
      t.index [ :firm_id, :project_id, :created_at ]
    end
  end
end
