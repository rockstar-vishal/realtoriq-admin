# frozen_string_literal: true

# Global master — where a lead came from. `category` groups the portals
# together so the source report can roll them up.
class LeadSource < ApplicationRecord
  CATEGORIES = %w[portal referral walk_in social outbound other].freeze

  validates :name, presence: true, uniqueness: { case_sensitive: false }
  validates :code, presence: true, uniqueness: true
  validates :category, inclusion: { in: CATEGORIES }

  before_validation :assign_code

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:sort_order, :name) }

  private

  def assign_code
    self.code = code.presence || name.to_s.parameterize(separator: "_")
  end
end
