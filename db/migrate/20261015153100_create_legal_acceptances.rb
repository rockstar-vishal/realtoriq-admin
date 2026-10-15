# frozen_string_literal: true

# The record of which terms the broker accepted. firm_id is nullable because an
# activated firm's acceptance is kept for three years after the firm is destroyed.
class CreateLegalAcceptances < ActiveRecord::Migration[8.0]
  def change
    create_table :legal_acceptances, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :onboarding_application, foreign_key: { on_delete: :nullify }, type: :uuid
      t.references :firm, foreign_key: { on_delete: :nullify }, type: :uuid

      t.string :terms_version, null: false
      t.string :terms_sha256, null: false
      t.string :privacy_version, null: false
      t.string :privacy_sha256, null: false
      t.text :statement, null: false
      t.datetime :accepted_at, null: false
      t.string :ip
      t.string :user_agent, limit: 300
      t.jsonb :evidence, null: false, default: {}

      t.string :pdf_sha256
      t.datetime :pdf_generated_at
      t.datetime :emailed_at
      t.date :retain_until

      t.timestamps
    end

    add_index :legal_acceptances, :retain_until
  end
end
