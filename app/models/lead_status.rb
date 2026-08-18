# frozen_string_literal: true

# Global master — the lead pipeline. The is_dead / is_booked flags are what let
# the dead-leads and bookings reports be written without hardcoding status
# names in SQL.
class LeadStatus < ApplicationRecord
  validates :name, presence: true, uniqueness: { case_sensitive: false }
  validates :code, presence: true, uniqueness: true

  before_validation :assign_code

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:sort_order, :name) }
  scope :dead, -> { where(is_dead: true) }
  scope :booked, -> { where(is_booked: true) }

  private

  def assign_code
    self.code = code.presence || name.to_s.parameterize(separator: "_")
  end
end
