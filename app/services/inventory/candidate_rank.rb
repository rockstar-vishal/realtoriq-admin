# frozen_string_literal: true

module Inventory
  # Where one listing sits for one lead. Nil means it is not a match.
  # With anchor matching off, bands are a tagged pin's 6 km circle, then
  # preferred localities, then neighbor localities. With it on, the anchor
  # circle replaces the pin circle. Score never moves a row up a band.
  class CandidateRank
    Decision = Data.define(
      :location_points, :nearby, :near_shortlist, :group, :distance_m, :band,
      :ring, :anchor, :shown_distance_m, :distance_rounded
    ) do
      def initialize(location_points:, nearby:, near_shortlist:, group:, distance_m:, band:,
        ring: nil, anchor: nil, shown_distance_m: nil, distance_rounded: false)
        super
      end
    end

    def self.decide(hooks:, locality_id:, lat:, lng:, locality_lat:, locality_lng:,
      round_distance: false, skip_listing: nil, approximate: false)
      new(
        hooks:, locality_id:, lat:, lng:, locality_lat:, locality_lng:,
        round_distance:, skip_listing:, approximate:
      ).decide
    end

    # `tie` is the row id. Equal scores and names must not swap between scans.
    def self.sort_key(ranking:, decision:, score:, name:, pre_leased_first: false, tie:)
      label = name.to_s.downcase
      id = tie.to_s
      pl = pre_leased_first ? 0 : 1
      return [ -score, pl, label, id ] unless ranking

      distance = decision.distance_m || 1_000_000_000
      case decision.band
      when :anchor then [ 0, decision.ring, -score, pl, distance, label, id ]
      when :pin then [ 0, distance, -score, pl, label, id ]
      when :preferred then [ 1, 0, -score, pl, distance, label, id ]
      else [ 1, 1, distance, -score, pl, label, id ]
      end
    end

    def initialize(hooks:, locality_id:, lat:, lng:, locality_lat:, locality_lng:,
      round_distance: false, skip_listing: nil, approximate: false)
      @hooks = hooks
      @locality_id = locality_id
      @own_point = Geo.own_pin(lat:, lng:, locality_lat:, locality_lng:, approximate:)
      @point = Geo.listing_point(lat:, lng:, locality_lat:, locality_lng:, approximate:)
      @round_distance = round_distance
      @skip_listing = skip_listing
    end

    def decide
      return preferred_only unless hooks.ranking?
      return decide_anchors if hooks.anchor_mode?

      pin, pin_m = nearest_pin(point, hooks.pins)
      in_circle = pin_m && pin_m <= Geo::NEARBY_M
      preferred = hooks.preferred?(locality_id)
      neighbor_m = hooks.neighbor_distance[locality_id]

      if in_circle
        finish(decision(:pin, pin_m, preferred), nearest: pin)
      elsif preferred
        finish(decision(:preferred, Geo.nearest_m(point, hooks.centers), true), nearest: nil)
      elsif neighbor_m
        finish(decision(:neighbor, neighbor_m, false), nearest: nil)
      end
    end

    private

    attr_reader :hooks, :locality_id, :point, :own_point, :round_distance, :skip_listing

    def decide_anchors
      preferred = hooks.preferred?(locality_id)
      if own_point
        anchor, metres = nearest_anchor
        ring = anchor && Geo.ring_for(metres, radius_m: hooks.anchor_radius_m)
        if ring
          return finish(anchor_decision(anchor, metres, ring, preferred), nearest: anchor)
        end
      end

      if preferred
        finish(decision(:preferred, Geo.nearest_m(point, hooks.centers), true), nearest: nil)
      elsif (neighbor_m = hooks.neighbor_distance[locality_id])
        finish(decision(:neighbor, neighbor_m, false), nearest: nil)
      end
    end

    def preferred_only
      return unless hooks.preferred?(locality_id)

      finish(decision(:preferred, nil, true), nearest: nil)
    end

    def anchor_decision(anchor, metres, ring, preferred)
      ring_number, points = ring
      Decision.new(
        location_points: preferred ? MatchScore::LOCATION_POINTS : points,
        nearby: !preferred,
        near_shortlist: anchor.kind != "placed",
        group: preferred ? "locality" : "nearby",
        distance_m: metres,
        band: :anchor,
        ring: ring_number,
        anchor:
      )
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

    # Shown metres follow the band. Sorting keeps the raw distance_m.
    def finish(decision, nearest:)
      raw = shown_raw(decision, nearest)
      source = decision.band == :anchor ? decision.anchor : nearest
      shown, rounded = apply_rounding(raw, source)
      decision.with(shown_distance_m: shown, distance_rounded: rounded)
    end

    def shown_raw(decision, nearest)
      case decision.band
      when :pin
        return unless own_point && nearest && nearest[:own]

        decision.distance_m
      when :anchor
        decision.distance_m
      when :preferred
        nil
      when :neighbor
        own_point ? Geo.nearest_m(own_point, hooks.centers) : nil
      end
    end

    def apply_rounding(raw, source)
      return [ raw, false ] if raw.nil?
      return [ raw, false ] unless round_distance || other_firm?(source)

      [ Geo.rounded_m(raw), true ]
    end

    def other_firm?(source)
      return false if source.nil?

      source.respond_to?(:other_firm) ? source.other_firm : source[:other_firm]
    end

    def nearest_pin(origin, pins)
      best = nil
      best_m = nil
      Array(pins).each do |pin|
        next if pin.nil? || origin.nil?

        metres = Geo.distance_m(origin[:lat], origin[:lng], pin[:lat], pin[:lng])
        next unless best_m.nil? || metres < best_m

        best = pin
        best_m = metres
      end
      [ best, best_m ]
    end

    def nearest_anchor
      best = nil
      best_m = nil
      hooks.anchors.each do |anchor|
        next if skipped?(anchor)

        metres = Geo.distance_m(own_point[:lat], own_point[:lng], anchor.lat, anchor.lng)
        next unless best_m.nil? || metres < best_m

        best = anchor
        best_m = metres
      end
      [ best, best_m ]
    end

    def skipped?(anchor)
      return false if skip_listing.nil?
      return false if anchor.listing_kind != skip_listing[:kind]

      Array(skip_listing[:ids]).include?(anchor.listing_id)
    end
  end
end
