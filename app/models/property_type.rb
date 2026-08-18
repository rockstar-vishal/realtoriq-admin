# frozen_string_literal: true

# Global master — under construction vs ready possession. Asked for sale leads
# and deliberately not asked for rental ones.
class PropertyType < ApplicationRecord
  validates :name, presence: true, uniqueness: { case_sensitive: false }
  validates :code, presence: true, uniqueness: true

  before_validation :assign_code

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:sort_order, :name) }

  private

  def assign_code
    self.code = code.presence || name.to_s.parameterize(separator: "_")
  end
end
