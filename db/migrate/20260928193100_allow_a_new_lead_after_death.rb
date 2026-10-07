# frozen_string_literal: true

# A dead lead no longer occupies (firm, mobile, transaction type). open_identity
# is the mobile while the lead is live and null once it is dead, so the unique
# index ignores dead rows.
class AllowANewLeadAfterDeath < ActiveRecord::Migration[8.0]
  def up
    add_column :leads, :open_identity, :string

    execute <<~SQL.squish
      UPDATE leads
      SET open_identity = leads.mobile
      FROM lead_statuses
      WHERE lead_statuses.id = leads.lead_status_id
        AND lead_statuses.is_dead = false
    SQL

    remove_index :leads, name: "index_leads_on_firm_mobile_transaction_type"

    add_index :leads, [ :firm_id, :transaction_type, :open_identity ],
      unique: true,
      where: "open_identity IS NOT NULL",
      name: "index_leads_on_firm_type_and_open_identity"
  end

  def down
    remove_index :leads, name: "index_leads_on_firm_type_and_open_identity"
    add_index :leads, [ :firm_id, :mobile, :transaction_type ],
      unique: true,
      name: "index_leads_on_firm_mobile_transaction_type"
    remove_column :leads, :open_identity
  end
end
