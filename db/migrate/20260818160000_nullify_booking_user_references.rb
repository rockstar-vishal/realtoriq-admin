# frozen_string_literal: true

# Same rule as NullifyUserReferencesOnDelete, extended to the booking tables:
# when a broker leaves, the firm's bookings and documents survive — they just
# stop naming who made them. Money records must outlive staff.
#
# Done in the database rather than with `dependent: :nullify` so it holds for
# deletes that never touch Ruby, and so destroying a firm doesn't depend on the
# order its associations happen to be declared in.
class NullifyBookingUserReferences < ActiveRecord::Migration[8.0]
  REFERENCES = [
    [ :bookings, :created_by_user_id ],
    [ :booking_documents, :uploaded_by_user_id ]
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
