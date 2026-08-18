# frozen_string_literal: true

# One row per signed-in admin browser. The signed cookie carries this row's id,
# so revoking a session is a delete rather than a token blocklist.
class AdminSession < ApplicationRecord
  IDLE_TIMEOUT = 12.hours

  belongs_to :admin_user

  scope :live, -> { where(last_seen_at: IDLE_TIMEOUT.ago..) }

  def expired? = last_seen_at.blank? || last_seen_at < IDLE_TIMEOUT.ago

  def touch_seen!
    # Only write once a minute — otherwise every page view is a write.
    return if last_seen_at.present? && last_seen_at > 1.minute.ago

    update_column(:last_seen_at, Time.current)
  end
end
