# frozen_string_literal: true

# Reporting line. A user may have several managers; recursion through this
# table is what `User#manageables` walks. Superadmins are not stored here —
# they already see the whole firm.
class CreateUserManagers < ActiveRecord::Migration[8.0]
  def change
    create_table :user_managers, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :firm, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :manager, null: false, foreign_key: { to_table: :users, on_delete: :cascade }, type: :uuid
      t.timestamps
    end

    add_index :user_managers, [ :user_id, :manager_id ],
      unique: true, name: "index_user_managers_on_user_and_manager"
    add_index :user_managers, [ :firm_id, :manager_id ],
      name: "index_user_managers_on_firm_and_manager"

    add_check_constraint :user_managers, "user_id <> manager_id",
      name: "user_managers_no_self"
  end
end
