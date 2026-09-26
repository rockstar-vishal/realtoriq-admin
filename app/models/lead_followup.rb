# frozen_string_literal: true

# One discussion the broker had with a lead. The comment is the log; the
# datetime is the NCD promised on that row. The lead's current NCD is a copy
# written by Leads::RecordFollowup, not this association.
class LeadFollowup < ApplicationRecord
  include FirmScoped

  belongs_to :lead, -> { unscope(where: :firm_id) }
  belongs_to :user, -> { unscope(where: :firm_id) }, optional: true

  validates :comment, presence: true

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }
end
