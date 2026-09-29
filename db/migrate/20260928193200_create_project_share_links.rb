# frozen_string_literal: true

class CreateProjectShareLinks < ActiveRecord::Migration[8.0]
  def change
    create_table :project_share_links, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: true, type: :uuid
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.references :project, null: false, foreign_key: true, type: :uuid
      t.string :token, null: false

      t.timestamps
    end

    add_index :project_share_links, :token, unique: true
    add_index :project_share_links, [ :firm_id, :user_id, :project_id ],
      unique: true,
      name: "index_project_share_links_on_firm_user_and_project"
  end
end
