# frozen_string_literal: true

# One direction of a same-city pair. The other direction is its own row, so
# "neighbors of Kharghar" is `where(locality_id:)`. Not firm-owned.
class LocalityNeighbor < ApplicationRecord
  belongs_to :locality
  belongs_to :neighbor_locality, class_name: "Locality"

  validates :distance_m, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: Inventory::Geo::NEARBY_M }
end
