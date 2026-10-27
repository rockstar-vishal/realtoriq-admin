# frozen_string_literal: true

module Localities
  # Fills blank locality centers. A hand-set center is left alone. When at
  # least three inventory pins exist and they disagree with the geocode by
  # more than 5 km, the center stays blank for someone to check.
  class GeocodeCenters
    ALIASES = { "Napean Sea Road" => "Nepean Sea Road" }.freeze

    def self.call(client:)
      new(client:).call
    end

    # One locality. Returns its city id when a centre was saved, otherwise nil.
    # A hand-set centre is the caller's concern. Saving runs Locality's
    # neighbour rebuild unless the caller is inside skipping_neighbor_rebuild.
    def self.fill_one(locality, client:)
      new(client:).fill_one(locality)
    end

    def initialize(client:)
      @client = client
    end

    def call
      city_ids = []
      Locality.skipping_neighbor_rebuild do
        Locality.includes(:city).where(lat: nil).find_each do |locality|
          city_ids << self.class.fill_one(locality, client:)
        end
      end
      city_ids.compact.uniq.each { |city_id| Inventory::RebuildLocalityNeighbors.call(city_id:) }
    end

    def fill_one(locality)
      fill(locality)
    end

    private

    attr_reader :client

    # City id when the centre was saved, so the rake task can rebuild once
    # per city. Nil when Google has nothing, the point is outside India, or
    # the inventory median disagrees.
    def fill(locality)
      found = client.coordinates(query_for(locality))
      return if found.nil?
      return unless Inventory::Geo.inside_india?(*found)

      median = inventory_median(locality)
      if median && Inventory::Geo.distance_m(*found, *median) > Inventory::Geo::CENTER_DISAGREEMENT_M
        $stdout.puts(
          "review #{locality.display_name}: geocode #{format_point(found)} inventory #{format_point(median)}"
        )
        return
      end

      locality.update!(lat: found[0], lng: found[1])
      locality.city_id
    end

    def query_for(locality)
      name = ALIASES.fetch(locality.name, locality.name)
      city = locality.city
      [ name, city&.name, city&.state.to_s.strip.presence, "India" ].compact.join(", ")
    end

    def inventory_median(locality)
      points = Project.unscoped.where(locality_id: locality.id, pin_approximate: false).where.not(lat: nil, lng: nil).pluck(:lat, :lng)
      points += Property.unscoped.where(locality_id: locality.id, pin_approximate: false).where.not(lat: nil, lng: nil).pluck(:lat, :lng)
      return if points.size < 3

      [ median(points.map { |lat, _lng| lat.to_f }), median(points.map { |_lat, lng| lng.to_f }) ]
    end

    def median(values)
      ordered = values.sort
      mid = ordered.length / 2
      return ordered[mid] if ordered.length.odd?

      (ordered[mid - 1] + ordered[mid]) / 2.0
    end

    def format_point(point)
      "#{point[0]},#{point[1]}"
    end
  end
end
