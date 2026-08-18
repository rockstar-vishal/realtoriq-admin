# frozen_string_literal: true

# Global master. Localities belong to a city; buildings (which are firm-owned)
# point at these.
class Locality < ApplicationRecord
  belongs_to :city

  validates :name, presence: true, uniqueness: { scope: :city_id, case_sensitive: false }
  validates :pincode, format: { with: /\A\d{6}\z/ }, allow_blank: true

  scope :active, -> { where(active: true) }
  scope :alphabetical, -> { order(:name) }

  def display_name = "#{name}, #{city.name}"
end
