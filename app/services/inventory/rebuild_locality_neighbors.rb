# frozen_string_literal: true

module Inventory
  # Rewrites one city's neighbor pairs from the centers stored on localities.
  # About 137 localities in the whole master list, so the pairwise check stays
  # in this process. A center that is blank drops its pairs.
  class RebuildLocalityNeighbors
    def self.call(city_id:)
      new(city_id:).call
    end

    def initialize(city_id:)
      @city_id = city_id
    end

    def call
      LocalityNeighbor.transaction do
        LocalityNeighbor.where(locality_id: Locality.where(city_id:).select(:id)).delete_all
        rows = pairs
        LocalityNeighbor.insert_all!(rows) if rows.any?
      end
    end

    private

    attr_reader :city_id

    def pairs
      located.combination(2).flat_map do |left, right|
        metres = Geo.distance_m(left.lat, left.lng, right.lat, right.lng)
        next [] if metres > Geo::NEARBY_M || metres.zero?

        now = Time.current
        [ row(left, right, metres, now), row(right, left, metres, now) ]
      end
    end

    def located
      @located ||= Locality.where(city_id:).where.not(lat: nil, lng: nil).to_a
    end

    def row(locality, neighbor, metres, now)
      {
        id: UuidV7.generate,
        locality_id: locality.id,
        neighbor_locality_id: neighbor.id,
        distance_m: metres,
        created_at: now,
        updated_at: now
      }
    end
  end
end
