# frozen_string_literal: true

# Append-only record of pipeline movement.
#
# Separate from LeadActivity because the dead-leads report needs the month a
# lead died, and a mutable status column cannot answer that. Read-only once
# written — if these can be edited, the report is no longer evidence.
class LeadStatusChange < ApplicationRecord
  include FirmScoped

  # Unscoped for the reason documented on Lead.
  belongs_to :lead, -> { unscope(where: :firm_id) }
  belongs_to :from_status, class_name: "LeadStatus", optional: true
  belongs_to :to_status, class_name: "LeadStatus"
  belongs_to :user, -> { unscope(where: :firm_id) }, optional: true

  validates :changed_at, presence: true

  scope :recent_first, -> { order(changed_at: :desc) }
  # What the dead-leads report groups over.
  scope :into_dead, -> { joins(:to_status).where(lead_statuses: { is_dead: true }) }

  def readonly? = persisted?
end
