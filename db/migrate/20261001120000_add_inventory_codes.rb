# frozen_string_literal: true

# Broker-facing codes for the lead import sheet. Random, global, and separate
# from LaunchIQ's external_ref. Keep the alphabet in step with InventoryCode.
class AddInventoryCodes < ActiveRecord::Migration[8.0]
  ALPHABET = (("A".."Z").to_a - %w[I O] + ("2".."9").to_a).freeze
  PROJECT_FORMAT = "^P-[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$"
  PROPERTY_FORMAT = "^H-[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$"

  def up
    add_column :projects, :code, :string
    add_column :properties, :code, :string

    backfill("projects", "P")
    backfill("properties", "H")

    change_column_null :projects, :code, false
    change_column_null :properties, :code, false
    add_index :projects, :code, unique: true, name: "index_projects_on_code"
    add_index :properties, :code, unique: true, name: "index_properties_on_code"
    add_check_constraint :projects, "code ~ '#{PROJECT_FORMAT}'", name: "projects_code_format"
    add_check_constraint :properties, "code ~ '#{PROPERTY_FORMAT}'", name: "properties_code_format"
  end

  def down
    remove_check_constraint :projects, name: "projects_code_format"
    remove_check_constraint :properties, name: "properties_code_format"
    remove_column :projects, :code
    remove_column :properties, :code
  end

  private

  def backfill(table, prefix)
    seen = {}
    select_values("SELECT id::text FROM #{table}").each do |id|
      code = unused_code(table, prefix, seen)
      execute("UPDATE #{table} SET code = #{quote(code)} WHERE id = #{quote(id)}")
    end
  end

  def unused_code(table, prefix, seen)
    loop do
      code = "#{prefix}-#{Array.new(6) { ALPHABET.sample }.join}"
      next if seen[code]
      next if select_value("SELECT 1 FROM #{table} WHERE code = #{quote(code)}")

      seen[code] = true
      return code
    end
  end
end
