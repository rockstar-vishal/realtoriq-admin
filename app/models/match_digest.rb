# frozen_string_literal: true

# The firm's current curated match list. One row, overwritten every cycle.
# notification_pending means a night run found something and the morning
# releaser has not told the super admin yet.
class MatchDigest < ApplicationRecord
  include FirmScoped

  validates :generated_at, :fingerprint, presence: true
end
