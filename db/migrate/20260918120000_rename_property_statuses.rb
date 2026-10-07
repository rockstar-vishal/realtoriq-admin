# frozen_string_literal: true

class RenamePropertyStatuses < ActiveRecord::Migration[8.0]
  def up
    remove_check_constraint :properties, name: "properties_status_check"

    execute "UPDATE properties SET status = 'booked' WHERE status = 'under_offer'"
    execute "UPDATE properties SET status = 'sold_out' WHERE status = 'closed'"

    add_check_constraint :properties,
      "status::text = ANY (ARRAY['available'::character varying::text, 'booked'::character varying::text, 'sold_out'::character varying::text])",
      name: "properties_status_check"
  end

  def down
    remove_check_constraint :properties, name: "properties_status_check"

    execute "UPDATE properties SET status = 'under_offer' WHERE status = 'booked'"
    execute "UPDATE properties SET status = 'closed' WHERE status = 'sold_out'"

    add_check_constraint :properties,
      "status::text = ANY (ARRAY['available'::character varying::text, 'under_offer'::character varying::text, 'closed'::character varying::text])",
      name: "properties_status_check"
  end
end
