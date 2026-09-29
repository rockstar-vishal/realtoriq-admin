# frozen_string_literal: true

# A training going live writes one inbox row per broker, so the kind has to be
# allowed by the CHECK constraint as well as by Notification::KINDS.
class AllowTrainingPublishedNotifications < ActiveRecord::Migration[8.0]
  def up
    remove_check_constraint :notifications, name: "notifications_kind_check"
    add_check_constraint :notifications,
      "kind IN ('followup_due', 'test', 'training_published')",
      name: "notifications_kind_check"
  end

  def down
    remove_check_constraint :notifications, name: "notifications_kind_check"
    add_check_constraint :notifications,
      "kind IN ('followup_due', 'test')",
      name: "notifications_kind_check"
  end
end
