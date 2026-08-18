# frozen_string_literal: true

# One table for both jobs a short-lived code does here:
#   - login: proving a broker holds the mobile they claim
#   - verify_*: proving a firm controls a contact channel
#
# Deliberately NOT firm-scoped. A login code is created before we know who is
# signing in, so a fail-closed tenant scope would make sign-in impossible.
class CreateOneTimeCodes < ActiveRecord::Migration[8.0]
  def change
    create_table :one_time_codes, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :purpose, null: false

      # Where the code was actually sent — kept alongside the association so the
      # record still explains itself if the channel is later edited.
      t.string :destination, null: false

      t.references :user, foreign_key: true, type: :uuid
      t.references :contact_channel, foreign_key: true, type: :uuid

      # bcrypt digest. A code is never stored in clear, in the database or the
      # logs — a leaked backup shouldn't hand over live sign-in codes.
      t.string :code_digest, null: false

      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.integer  :attempts, null: false, default: 0
      t.integer  :max_attempts, null: false, default: 5

      t.string :request_ip

      t.timestamps
    end

    add_index :one_time_codes, [ :purpose, :destination, :created_at ]
    add_index :one_time_codes, :expires_at

    add_check_constraint :one_time_codes,
      "purpose IN ('login', 'verify_email', 'verify_mobile', 'verify_whatsapp')",
      name: "one_time_codes_purpose_check"
  end
end
