# frozen_string_literal: true

# Ops-managed billing. No payment gateway in this build: someone in ops sets a
# firm's plan and renews it by hand. The shape is the one a gateway would want
# later, so adding Razorpay is an integration rather than a migration.
class CreatePlansAndSubscriptions < ActiveRecord::Migration[8.0]
  def change
    create_table :plans, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :name, null: false
      t.string :code, null: false
      # Whole rupees. See docs/schema.md for the money rule.
      t.bigint :price, null: false, default: 0
      t.string :interval, null: false, default: "month"

      t.integer :max_users
      t.integer :max_devices, null: false, default: 3

      t.jsonb :features, null: false, default: {}
      t.boolean :active, null: false, default: true
      t.integer :sort_order, null: false, default: 0

      t.timestamps
    end

    add_index :plans, :code, unique: true

    add_check_constraint :plans, "interval IN ('month', 'year')", name: "plans_interval_check"
    add_check_constraint :plans, "price >= 0", name: "plans_price_check"

    create_table :subscriptions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: true, type: :uuid
      t.references :plan, null: false, foreign_key: true, type: :uuid

      t.string :status, null: false, default: "active"

      t.date :current_period_start, null: false
      t.date :current_period_end, null: false

      # Snapshot of what was charged, so changing a plan's price later doesn't
      # rewrite history.
      t.bigint :amount, null: false, default: 0

      t.datetime :trial_ends_at
      t.datetime :cancelled_at
      t.string   :cancel_reason

      t.references :created_by_admin, foreign_key: { to_table: :admin_users }, type: :uuid

      t.timestamps
    end

    # One live subscription per firm; superseded ones stay as history.
    add_index :subscriptions, :firm_id,
      unique: true,
      where: "status IN ('trialing', 'active')",
      name: "index_subscriptions_one_live_per_firm"

    add_index :subscriptions, [ :status, :current_period_end ]

    add_check_constraint :subscriptions,
      "status IN ('trialing', 'active', 'past_due', 'lapsed', 'cancelled')",
      name: "subscriptions_status_check"

    add_check_constraint :subscriptions,
      "current_period_end >= current_period_start",
      name: "subscriptions_period_check"
  end
end
