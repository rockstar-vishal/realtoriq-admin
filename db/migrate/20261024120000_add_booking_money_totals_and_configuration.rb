# frozen_string_literal: true

# The bookings list filters and sums in SQL. invoiced_amount and collected_amount
# are the raised-invoice and collection sums, stored so a page of rows is not
# what the header adds up. They are filled here from those rows, and rewritten
# by RaiseInvoice and RecordCollection after every later write.
#
# project_typology_id points at the project's configuration row. A project save
# replaces those rows and nulls the pointer, so typology_id and
# configuration_label store what was booked. The typologies master is not
# replaced by that save. Nothing is backfilled.
class AddBookingMoneyTotalsAndConfiguration < ActiveRecord::Migration[8.0]
  def up
    add_column :bookings, :invoiced_amount, :bigint, null: false, default: 0
    add_column :bookings, :collected_amount, :bigint, null: false, default: 0
    add_reference :bookings, :project_typology, type: :uuid, index: true,
      foreign_key: { on_delete: :nullify }
    add_reference :bookings, :typology, type: :uuid, index: true, foreign_key: true
    add_column :bookings, :configuration_label, :string

    execute <<~SQL.squish
      UPDATE bookings
      SET invoiced_amount = COALESCE((
            SELECT SUM(invoices.amount)
            FROM invoices
            WHERE invoices.booking_id = bookings.id
              AND invoices.status = 'raised'
          ), 0),
          collected_amount = COALESCE((
            SELECT SUM(collections.amount)
            FROM collections
            WHERE collections.booking_id = bookings.id
          ), 0)
    SQL

    add_check_constraint :bookings, "invoiced_amount >= 0", name: "bookings_invoiced_amount_nonnegative"
    add_check_constraint :bookings, "collected_amount >= 0", name: "bookings_collected_amount_nonnegative"
  end

  def down
    remove_check_constraint :bookings, name: "bookings_invoiced_amount_nonnegative"
    remove_check_constraint :bookings, name: "bookings_collected_amount_nonnegative"
    # This migration was edited before it shipped. A database that already ran
    # the first version has the money columns and not the snapshot columns.
    remove_column :bookings, :configuration_label if column_exists?(:bookings, :configuration_label)
    if column_exists?(:bookings, :typology_id)
      remove_reference :bookings, :typology, type: :uuid, foreign_key: true, index: true
    end
    remove_reference :bookings, :project_typology, type: :uuid, foreign_key: true, index: true
    remove_column :bookings, :invoiced_amount, :bigint
    remove_column :bookings, :collected_amount, :bigint
  end
end
