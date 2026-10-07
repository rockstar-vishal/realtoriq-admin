# frozen_string_literal: true

# One outing that already happened. The date is an IST calendar day stored as
# the start of that day. Sites are optional; a siteless row still counts on
# the lead and does not mark any project or property visited.
class LeadVisit < ApplicationRecord
  include FirmScoped

  belongs_to :lead, -> { unscope(where: :firm_id) }
  belongs_to :user, -> { unscope(where: :firm_id) }, optional: true
  belongs_to_same_firm :lead, :user

  has_many :lead_visit_projects, -> { unscope(where: :firm_id) }, dependent: :destroy
  has_many :lead_visit_properties, -> { unscope(where: :firm_id) }, dependent: :destroy
  has_many :projects, -> { unscope(where: :firm_id) }, through: :lead_visit_projects
  has_many :properties, -> { unscope(where: :firm_id) }, through: :lead_visit_properties

  validates :visited_at, presence: true

  scope :recent_first, -> { order(visited_at: :desc, created_at: :desc) }

  def visited_on
    visited_at.in_time_zone(Lead::NCD_ZONE).to_date.iso8601
  end
end
