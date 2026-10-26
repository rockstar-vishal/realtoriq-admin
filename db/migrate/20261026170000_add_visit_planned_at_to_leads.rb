# frozen_string_literal: true

# The visit time on a Visit Planned lead. Null on every other status, and on
# Visit Planned rows that were stored before this column existed. No backfill:
# those leads keep working, and a visit is due only once a time is saved.
class AddVisitPlannedAtToLeads < ActiveRecord::Migration[8.0]
  def change
    add_column :leads, :visit_planned_at, :datetime
  end
end
