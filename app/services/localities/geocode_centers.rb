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

    def initialize(client:)
      @client = client
      @cities = []
    end

    def call
      Locality.skipping_neighbor_rebuild do
        Locality.includes(:city).where(lat: nil).find_each { |locality| fill(locality) }
      end
      @cities.uniq.each { |city_id| Inventory::RebuildLocalityNeighbors.call(city_id:) }
    end

    private

    attr_reader :client

    def fill(locality)
      found = client.coordinates("#{ALIASES.fetch(locality.name, locality.name)}, Maharashtra, India")
      return if found.nil?
      return unless Inventory::Geo.inside_maharashtra?(*found)

      median = inventory_median(locality)
      if median && Inventory::Geo.distance_m(*found, *median) > Inventory::Geo::CENTER_DISAGREEMENT_M
        $stdout.puts(
          "review #{locality.display_name}: geocode #{format_point(found)} inventory #{format_point(median)}"
        )
        return
      end

      locality.update!(lat: found[0], lng: found[1])
      @cities << locality.city_id
    end

    def inventory_median(locality)
      points = Project.unscoped.where(locality_id: locality.id).where.not(lat: nil, lng: nil).pluck(:lat, :lng)
      points += Building.unscoped.where(locality_id: locality.id).where.not(lat: nil, lng: nil).pluck(:lat, :lng)
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
