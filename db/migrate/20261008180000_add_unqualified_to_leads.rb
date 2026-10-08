# frozen_string_literal: true

# Matching used to skip every dead lead. Dead is a pipeline stage and is
# reversible, so it is the wrong gate. This flag is the gate. Existing rows
# stay eligible: there is no stored signal for which dead leads were junk.
class AddUnqualifiedToLeads < ActiveRecord::Migration[8.0]
  def change
    add_column :leads, :unqualified, :boolean, default: false, null: false
  end
end
