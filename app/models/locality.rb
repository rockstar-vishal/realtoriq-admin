# frozen_string_literal: true

# Global master. Localities belong to a city; buildings (which are firm-owned)
# point at these.
class Locality < ApplicationRecord
  belongs_to :city

  validates :name, presence: true, uniqueness: { scope: :city_id, case_sensitive: false }
  validates :pincode, format: { with: /\A\d{6}\z/ }, allow_blank: true
  validates :lat, :lng, numericality: true, allow_nil: true
  validate :coordinates_are_a_pair
  validate :coordinates_are_in_maharashtra

  after_commit :rebuild_neighbor_pairs, if: :saved_change_to_coordinates?

  scope :active, -> { where(active: true) }
  scope :alphabetical, -> { order(:name) }

  def self.skipping_neighbor_rebuild
    previous = Thread.current[:skip_locality_neighbors]
    Thread.current[:skip_locality_neighbors] = true
    yield
  ensure
    Thread.current[:skip_locality_neighbors] = previous
  end

  def display_name = "#{name}, #{city.name}"

  private

  def coordinates_are_a_pair
    return if lat.blank? == lng.blank?

    errors.add(:lat, "and longitude are set together")
  end

  def coordinates_are_in_maharashtra
    return if lat.blank? && lng.blank?
    return if Inventory::Geo.inside_maharashtra?(lat, lng)

    errors.add(:lat, "must be inside Maharashtra")
  end

  def saved_change_to_coordinates?
    saved_change_to_lat? || saved_change_to_lng?
  end

  def rebuild_neighbor_pairs
    return if Thread.current[:skip_locality_neighbors]

    Inventory::RebuildLocalityNeighbors.call(city_id:)
  end
end
