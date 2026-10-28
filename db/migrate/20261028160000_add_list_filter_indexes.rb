# frozen_string_literal: true

# Prospect name and mobile search are leading-wildcard matches, so a btree
# cannot serve them. The mobile expression is the one Prospect.mobile_like
# binds. Leads sorted by booked_at need (firm_id, booked_at).
class AddListFilterIndexes < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    add_index :prospects, :name,
      using: :gin, opclass: :gin_trgm_ops,
      name: "index_prospects_on_name_trgm",
      algorithm: :concurrently, if_not_exists: true

    # add_index drops the opclass on an expression, and gin has no default
    # opclass for text. The parentheses put gin_trgm_ops on the expression.
    execute <<~SQL.squish
      CREATE INDEX CONCURRENTLY IF NOT EXISTS index_prospects_on_mobile_digits_trgm
      ON prospects USING gin ((regexp_replace(mobile, '\\D', '', 'g')) gin_trgm_ops)
    SQL

    add_index :prospects, %i[firm_id created_at],
      name: "index_prospects_on_firm_id_and_created_at",
      algorithm: :concurrently

    # as_booked orders booked_at DESC NULLS LAST, then created_at DESC. A plain
    # ASC index scans backwards as DESC NULLS FIRST, so it cannot supply this
    # order. created_at is the tie-break in that same ORDER BY.
    execute <<~SQL.squish
      CREATE INDEX CONCURRENTLY index_leads_on_firm_id_and_booked_at
      ON leads (firm_id, booked_at DESC NULLS LAST, created_at DESC)
    SQL
  end

  def down
    remove_index :leads, name: "index_leads_on_firm_id_and_booked_at", algorithm: :concurrently
    remove_index :prospects, name: "index_prospects_on_firm_id_and_created_at", algorithm: :concurrently
    remove_index :prospects, name: "index_prospects_on_mobile_digits_trgm", algorithm: :concurrently
    remove_index :prospects, name: "index_prospects_on_name_trgm", algorithm: :concurrently
  end
end
