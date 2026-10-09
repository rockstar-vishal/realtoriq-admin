# frozen_string_literal: true

module Inventory
  # Metres between coordinates. Matching uses this after an indexed locality
  # lookup, or inside one 6 km box around a tagged pin. Not a city scan.
  module Geo
    NEARBY_M = 6_000
    PIN_DRIFT_M = 20_000
    CENTER_DISAGREEMENT_M = 5_000
    EARTH_M = 6_371_000.0
    METRES_PER_DEGREE = 111_320.0
    # Maharashtra, with margin. A swapped lat/lng falls outside.
    LAT_RANGE = (15.6..22.1)
    LNG_RANGE = (72.6..80.9)

    Box = Data.define(:min_lat, :max_lat, :min_lng, :max_lng)

    module_function

    def inside_maharashtra?(lat, lng)
      lat_f = numeric(lat)
      lng_f = numeric(lng)
      return false if lat_f.nil? || lng_f.nil?

      LAT_RANGE.cover?(lat_f) && LNG_RANGE.cover?(lng_f)
    end

    def distance_m(lat1, lng1, lat2, lng2)
      rlat1, rlng1, rlat2, rlng2 = [ lat1, lng1, lat2, lng2 ].map { |value| value.to_f * Math::PI / 180.0 }
      dlat = rlat2 - rlat1
      dlng = rlng2 - rlng1
      chord = Math.sin(dlat / 2)**2 + Math.cos(rlat1) * Math.cos(rlat2) * Math.sin(dlng / 2)**2
      (2 * EARTH_M * Math.atan2(Math.sqrt(chord), Math.sqrt(1 - chord))).round
    end

    def offset(lat, lng, north_m: 0, east_m: 0)
      lat_f = lat.to_f
      lng_f = lng.to_f
      dlat = north_m.to_f / METRES_PER_DEGREE
      dlng = east_m.to_f / (METRES_PER_DEGREE * Math.cos(lat_f * Math::PI / 180.0))
      [ lat_f + dlat, lng_f + dlng ]
    end

    # Slightly larger than 6 km so the degree approximation cannot drop an
    # edge row. Callers still reject anything past NEARBY_M.
    def box(lat, lng, metres: NEARBY_M + 150)
      lat_f = lat.to_f
      lng_f = lng.to_f
      dlat = metres.to_f / METRES_PER_DEGREE
      dlng = metres.to_f / (METRES_PER_DEGREE * Math.cos(lat_f * Math::PI / 180.0))
      Box.new(min_lat: lat_f - dlat, max_lat: lat_f + dlat, min_lng: lng_f - dlng, max_lng: lng_f + dlng)
    end

    # A building or project pin. Outside Maharashtra, or more than 20 km from
    # its own locality center, the center is used instead. A pin with no
    # center is kept only inside Maharashtra. Nil when nothing is usable.
    def listing_point(lat:, lng:, locality_lat:, locality_lng:)
      center = pair(locality_lat, locality_lng)
      pin = pair(lat, lng)
      if pin && inside_maharashtra?(*pin) && (center.nil? || distance_m(*pin, *center) <= PIN_DRIFT_M)
        return { lat: pin[0], lng: pin[1] }
      end
      return { lat: center[0], lng: center[1] } if center && inside_maharashtra?(*center)

      nil
    end

    def haversine_sql(lat_sql, lng_sql)
      <<~SQL.squish
        (6371000 * acos(LEAST(1.0, GREATEST(-1.0,
          cos(radians(:clat)) * cos(radians(#{lat_sql})) * cos(radians(#{lng_sql}) - radians(:clng))
          + sin(radians(:clat)) * sin(radians(#{lat_sql}))
        ))))
      SQL
    end

    # Localities whose centers fall in a pin box. An unpinned listing uses that
    # center, so the box has to see the locality, not only rows that stored a pin.
    def center_locality_ids(city_id:, min_lat:, max_lat:, min_lng:, max_lng:)
      return [] if city_id.blank?

      Locality.where(city_id:, lat: min_lat..max_lat, lng: min_lng..max_lng).pluck(:id)
    end

    def nearest_m(origin, points)
      return if origin.nil?

      points.filter_map { |point|
        next if point.nil?

        distance_m(origin[:lat], origin[:lng], point[:lat], point[:lng])
      }.min
    end

    def pair(lat, lng)
      lat_f = numeric(lat)
      lng_f = numeric(lng)
      return if lat_f.nil? || lng_f.nil?

      [ lat_f, lng_f ]
    end

    def numeric(value)
      return if value.nil?
      return if value.is_a?(String) && value.blank?

      value.to_f
    end
  end
end
