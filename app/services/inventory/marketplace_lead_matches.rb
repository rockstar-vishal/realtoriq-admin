# frozen_string_literal: true

module Inventory
  # Other firms' leads that clear the marketplace score floor on this property.
  # The client is not named. `firm_id` matches `marketplace_firms`, because
  # firm names are not unique. `code` is that firm's own lead code. Location
  # is the shared locality, and configuration is the lead's typology names.
  class MarketplaceLeadMatches
    LIMIT = MatchLeads::LIMIT

    def initialize(property:)
      @property = property
    end

    def call
      return [] unless property.listed_on_marketplace? && property.available?
      return [] if locality_id.blank? && listing_point.nil?
      return [] if Current.firm&.review_demo? || property.firm&.review_demo?

      scored
        .sort_by { |sort, row| sort + [ row[:firm_name].to_s.downcase, row[:code].to_s ] }
        .first(LIMIT)
        .map(&:last)
    end

    private

    attr_reader :property

    def locality_id
      listing_building&.locality_id
    end

    def listing_building
      @listing_building ||= Building.unscoped.includes(:locality).find_by(id: property.building_id)
    end

    def listing_point
      @listing_point ||= Geo.listing_point(
        lat: listing_building&.lat, lng: listing_building&.lng,
        locality_lat: listing_building&.locality&.lat, locality_lng: listing_building&.locality&.lng
      )
    end

    def search_locality_ids
      ids = [ locality_id ].compact
      return ids unless nearby_on?

      ids + LocalityNeighbor.where(locality_id: ids).pluck(:neighbor_locality_id)
    end

    def candidates
      scope = Lead.unscoped
        .where(firm_id: Firm.marketplace_eligible.where.not(id: property.firm_id).select(:id))
        .where(transaction_type: property.listing_for)
        .matchable
        .where(id: candidate_lead_ids)
        .includes(:firm, :typologies, :localities)
      scope = scope.joins(:property_type).where(property_types: { code: "ready_possession" }) if property.for_sale?
      scope.to_a
    end

    def candidate_lead_ids
      base = Lead.unscoped
        .where(firm_id: Firm.marketplace_eligible.where.not(id: property.firm_id).select(:id))
        .where(transaction_type: property.listing_for)
        .matchable
      ids = base.joins(:lead_localities).where(lead_localities: { locality_id: search_locality_ids }).pluck(:id)
      ids | tagged_lead_ids(base)
    end

    def tagged_lead_ids(base)
      return [] unless nearby_on? && listing_point && listing_building&.city_id

      box = Geo.box(listing_point[:lat], listing_point[:lng])
      center_ids = Geo.center_locality_ids(
        city_id: listing_building.city_id, min_lat: box.min_lat, max_lat: box.max_lat,
        min_lng: box.min_lng, max_lng: box.max_lng
      )
      TaggedLeads.ids(
        box:, city_id: listing_building.city_id, center_ids:, lead_scope: base, unscoped: true
      )
    end

    def nearby_on?
      return @nearby_on unless @nearby_on.nil?

      @nearby_on = NearbyMatching.enabled?
    end

    def scored
      rows = candidates
      index = HookIndex.for(rows, nearby: nearby_on?)
      rows.filter_map { |lead| scored_lead(lead, index) }
    end

    def scored_lead(lead, index)
      hooks = LeadHooks.for(lead, index:)
      decision = CandidateRank.decide(
        hooks:, locality_id:,
        lat: listing_building&.lat, lng: listing_building&.lng,
        locality_lat: listing_building&.locality&.lat, locality_lng: listing_building&.locality&.lng
      )
      return unless decision

      breakdown = MatchScore.for_offers(
        budget: lead.budget_amount,
        offers:,
        lead_keys: lead.typologies.map { |typology| ConfigurationKey.call(typology.name) },
        location_points: decision.location_points
      )
      return unless breakdown[:score] > MatchInventory::MARKETPLACE_FLOOR

      sort = if hooks.ranking?
        CandidateRank.sort_key(ranking: true, decision:, score: breakdown[:score], name: lead.firm&.name)
      else
        [ -breakdown[:score] ]
      end
      [ sort, row(lead).merge(distance_m: decision.distance_m, group: decision.group) ]
    end

    def offers
      @offers ||= [
        MatchScore::Offer.new(
          price: property.price,
          name: property.typology&.name,
          key: ConfigurationKey.call(property.typology&.name)
        )
      ]
    end

    def row(lead)
      {
        firm_id: lead.firm_id,
        firm_name: lead.firm&.name,
        code: lead.code,
        localities: [ property.building.locality&.name ].compact,
        configurations: lead.typologies.map(&:name).sort,
        marketplace: true
      }
    end
  end
end
