# frozen_string_literal: true

# Broker users. There is no self-signup anywhere in this product — ops create
# the firm's super_admin, who is then the only in-firm role that can add others
# or verify the firm's contact channels.
class CreateUsers < ActiveRecord::Migration[8.0]
  def change
    create_table :users, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: true, type: :uuid

      t.string :name, null: false
      t.string :email
      # E.164, and globally unique rather than unique-per-firm: the sign-in
      # screen has no subdomain or firm code to scope the lookup by, so the
      # mobile alone has to resolve to exactly one user.
      t.string :mobile, null: false

      t.string :role, null: false, default: "agent"
      t.string :status, null: false, default: "active"

      t.string :rera_number
      t.string :notification_mode, null: false, default: "all"

      t.datetime :last_seen_at

      # Three bad OTP codes locks sign-in for 30 minutes.
      t.integer  :failed_otp_attempts, null: false, default: 0
      t.datetime :otp_locked_until

      t.timestamps
    end

    add_index :users, :mobile, unique: true
    add_index :users, :email, unique: true, where: "email IS NOT NULL"
    add_index :users, [ :firm_id, :status ]

    # Exactly one super_admin per firm, enforced here rather than in a
    # validation, because a race between two admin requests would slip past
    # a Ruby-level uniqueness check.
    add_index :users, :firm_id,
      unique: true,
      where: "role = 'super_admin'",
      name: "index_users_one_super_admin_per_firm"

    add_check_constraint :users,
      "role IN ('super_admin', 'manager', 'agent')",
      name: "users_role_check"

    add_check_constraint :users,
      "status IN ('active', 'disabled')",
      name: "users_status_check"
  end
end
