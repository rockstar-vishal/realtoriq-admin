# frozen_string_literal: true

module Inventory
  # Where one listing sits for one lead. Nil means it is not a match.
  # Bands, in order: inside a tagged pin's 6 km circle, then preferred
  # localities, then neighbor localities. Score never moves a row up a band.
  class CandidateRank
    Decision = Data.define(:location_points, :nearby, :near_shortlist, :group, :distance_m, :band)

    def self.decide(hooks:, locality_id:, lat:, lng:, locality_lat:, locality_lng:)
      new(hooks:, locality_id:, lat:, lng:, locality_lat:, locality_lng:).decide
    end

    def self.sort_key(ranking:, decision:, score:, name:)
      label = name.to_s.downcase
      return [ -score, label ] unless ranking

      distance = decision.distance_m || 1_000_000_000
      case decision.band
      when :pin then [ 0, distance, -score, label ]
      when :preferred then [ 1, 0, -score, distance, label ]
      else [ 1, 1, distance, -score, label ]
      end
    end

    def initialize(hooks:, locality_id:, lat:, lng:, locality_lat:, locality_lng:)
      @hooks = hooks
      @locality_id = locality_id
      @point = Geo.listing_point(lat:, lng:, locality_lat:, locality_lng:)
    end

    def decide
      return preferred_only unless hooks.ranking?

      pin_m = Geo.nearest_m(point, hooks.pins)
      in_circle = pin_m && pin_m <= Geo::NEARBY_M
      preferred = hooks.preferred?(locality_id)
      neighbor_m = hooks.neighbor_distance[locality_id]

      if in_circle
        decision(:pin, pin_m, preferred)
      elsif preferred
        decision(:preferred, Geo.nearest_m(point, hooks.centers), true)
      elsif neighbor_m
        decision(:neighbor, neighbor_m, false)
      end
    end

    private

    attr_reader :hooks, :locality_id, :point

    def preferred_only
      return unless hooks.preferred?(locality_id)

      decision(:preferred, nil, true)
    end

    def decision(band, distance_m, preferred)
      points = preferred ? MatchScore::LOCATION_POINTS : MatchScore::NEARBY_POINTS
      Decision.new(
        location_points: points,
        nearby: !preferred,
        near_shortlist: band == :pin,
        group: preferred ? "locality" : "nearby",
        distance_m:,
        band:
      )
    end
  end
end
