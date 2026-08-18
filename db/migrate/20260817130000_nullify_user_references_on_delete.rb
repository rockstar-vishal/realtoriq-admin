# frozen_string_literal: true

# When a broker leaves, their leads and history must survive — unassigned, not
# deleted. That is the entire reason the reassign endpoint exists.
#
# Done in the database rather than with `dependent: :nullify` for two reasons:
# LeadStatusChange is deliberately readonly at the application layer, so Active
# Record cannot null its user_id; and a constraint holds for raw SQL deletes too,
# where a Ruby callback would not run at all.
class NullifyUserReferencesOnDelete < ActiveRecord::Migration[8.0]
  REFERENCES = [
    [ :leads, :assigned_user_id ],
    [ :lead_activities, :user_id ],
    [ :lead_status_changes, :user_id ]
  ].freeze

  def up
    REFERENCES.each do |table, column|
      remove_foreign_key table, column: column
      add_foreign_key table, :users, column: column, on_delete: :nullify
    end
  end

  def down
    REFERENCES.each do |table, column|
      remove_foreign_key table, column: column
      add_foreign_key table, :users, column: column
    end
  end
end
