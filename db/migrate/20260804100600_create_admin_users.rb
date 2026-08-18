# frozen_string_literal: true

# Platform staff. Deliberately a separate model from User (brokers): different
# credential type, different session mechanism, and no path by which a broker
# account can become an admin one.
#
# A single role for now — everyone who can sign in here can do everything, and
# there is no impersonation.
class CreateAdminUsers < ActiveRecord::Migration[8.0]
  def change
    create_table :admin_users, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :name, null: false
      t.string :email, null: false
      t.string :password_digest, null: false
      t.datetime :last_login_at
      t.boolean :active, null: false, default: true
      t.timestamps
    end

    add_index :admin_users, :email, unique: true

    # Cookie-based sessions: the signed cookie carries this row's id, so
    # revoking access is a delete rather than a token blocklist.
    create_table :admin_sessions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :admin_user, null: false, foreign_key: true, type: :uuid
      t.string :ip_address
      t.string :user_agent
      t.datetime :last_seen_at
      t.timestamps
    end
  end
end
