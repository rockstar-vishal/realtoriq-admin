# frozen_string_literal: true

# Soft delete for a registration that was rejected or left unactivated.
# There is no default scope: admin can still open the firm for 30 days.
class AddDiscardedAtToFirms < ActiveRecord::Migration[8.0]
  def change
    add_column :firms, :discarded_at, :datetime
    add_index :firms, :discarded_at
  end
end