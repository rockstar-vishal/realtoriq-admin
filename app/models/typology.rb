# frozen_string_literal: true

# Global master — 1 RK through Penthouse. `bedrooms` is decimal because half
# configurations (1.5 BHK, 2.5 BHK) are normal in this market, and it is what
# budget matching sorts on.
class Typology < ApplicationRecord
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
