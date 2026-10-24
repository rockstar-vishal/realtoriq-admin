# frozen_string_literal: true

module Inventory
  # Rewrites neighbor pairs from the centers stored on localities.
  # About 137 localities in the whole master list, so the pairwise check stays
  # in this process. A center that is blank drops its pairs.
  # Anchor matching pairs across cities. The switched-off path stays inside one city.
  class RebuildLocalityNeighbors
    def self.call(city_id:)
      if AnchorMatching.enabled?
        rebuild_all(across_cities: true)
      else
        new(city_id:).call
      end
    end

    def self.rebuild_all(across_cities:)
      raise ArgumentError, "across_cities must be true" unless across_cities

      located = Locality.where.not(lat: nil, lng: nil).to_a
      rows = pair_rows(located)
      LocalityNeighbor.transaction do
        LocalityNeighbor.delete_all
        LocalityNeighbor.insert_all!(rows) if rows.any?
      end
    end

    def self.pair_rows(located)
      located.combination(2).flat_map do |left, right|
        metres = Geo.distance_m(left.lat, left.lng, right.lat, right.lng)
        next [] if metres > Geo::NEARBY_M || metres.zero?

        now = Time.current
        [ row(left, right, metres, now), row(right, left, metres, now) ]
      end
    end

    def self.row(locality, neighbor, metres, now)
      {
        id: UuidV7.generate,
        locality_id: locality.id,
        neighbor_locality_id: neighbor.id,
        distance_m: metres,
        created_at: now,
        updated_at: now
      }
    end

    def initialize(city_id:)
      @city_id = city_id
    end

    def call
      LocalityNeighbor.transaction do
        LocalityNeighbor.where(locality_id: Locality.where(city_id:).select(:id)).delete_all
        rows = self.class.pair_rows(located)
        LocalityNeighbor.insert_all!(rows) if rows.any?
      end
    end

    private

    attr_reader :city_id

    def located
      @located ||= Locality.where(city_id:).where.not(lat: nil, lng: nil).to_a
    end
  end
end
