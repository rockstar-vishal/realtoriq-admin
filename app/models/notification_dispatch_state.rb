# frozen_string_literal: true

# Global watermark for a notification scanner. Not firm-owned: the job has no
# tenant and must not be hidden by FirmScoped's fail-closed default.
class NotificationDispatchState < ApplicationRecord
  validates :key, presence: true, uniqueness: true
end
