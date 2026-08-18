# frozen_string_literal: true

# One row per signed-in broker device.
#
# Access tokens are short-lived JWTs carrying this row's id; the refresh token
# is stored only as a digest. That combination is what makes "device limit
# reached" and remote sign-out possible — a JWT alone cannot be revoked.
class CreateAuthSessions < ActiveRecord::Migration[8.0]
  def change
    create_table :auth_sessions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      # Denormalised from the user so a session can be scoped and audited
      # without a join.
      t.references :firm, null: false, foreign_key: true, type: :uuid

      t.string :refresh_token_digest, null: false

      # Identifies the physical device, so re-installing the app replaces that
      # device's session rather than consuming another slot.
      t.string :device_id
      t.string :device_name
      t.string :platform
      t.string :app_version

      t.string :user_agent
      t.string :ip

      t.datetime :last_used_at
      t.datetime :expires_at, null: false
      t.datetime :revoked_at
      t.string   :revoked_reason

      t.timestamps
    end

    add_index :auth_sessions, [ :user_id, :revoked_at ]
    add_index :auth_sessions, :refresh_token_digest, unique: true
    add_index :auth_sessions, [ :user_id, :device_id ],
      unique: true,
      where: "revoked_at IS NULL AND device_id IS NOT NULL",
      name: "index_auth_sessions_one_live_per_device"
  end
end
