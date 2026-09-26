# frozen_string_literal: true

# One row in a broker's inbox. Push delivery is separate and may fail.
class Notification < ApplicationRecord
  include FirmScoped

  KINDS = %w[followup_due test].freeze

  belongs_to :user, -> { unscope(where: :firm_id) }
  belongs_to_same_firm :user

  validates :kind, inclusion: { in: KINDS }
  validates :title, :body, :dedupe_key, presence: true

  scope :unread, -> { where(read_at: nil) }
  scope :recent_first, -> { order(created_at: :desc, id: :desc) }
end
