# frozen_string_literal: true

module Inventory
  # Leads in this firm that share a locality with this project or property.
  # An agent sees only leads assigned to them. Dead leads stay eligible.
  # Unqualified leads and booked leads do not.
  class MatchLeads
    LIMIT = 50
    OWN_FLOOR = MatchInventory::OWN_FLOOR
    MARKETPLACE_FLOOR = MatchInventory::MARKETPLACE_FLOOR

    def initialize(user:, project: nil, property: nil)
      @user = user
      @project = project
      @property = property
    end

    def call
      return [] if locality_id.blank? && !nearby_on?
      return [] if project && !project.active?
      return [] if property && !property.available?
      return [] if locality_id.blank? && listing_point.nil?

      scored
        .select { |row| row[:score] > floor }
        .sort_by { |row| row[:sort] }
        .first(LIMIT)
    end

    private

    attr_reader :user, :project, :property

    def locality_id
      project ? project.locality_id : listing_building&.locality_id
    end

    def transaction_type
      property ? property.listing_for : "sale"
    end

    def floor
      return MARKETPLACE_FLOOR if project&.marketplace?
      # Another firm's shared listing. Same bar as marketplace inventory on a lead.
      return MARKETPLACE_FLOOR if property && property.firm_id != user.firm_id

      OWN_FLOOR
    end

    def leads
      scope = Lead.visible_to(user)
        .where(transaction_type:)
        .matchable
        .where(id: candidate_lead_ids)
        .includes(:typologies, :localities, :lead_projects, :lead_properties, :property_type, :lead_status)
      property_type_scope(scope).to_a
    end

    def candidate_lead_ids
      base = Lead.visible_to(user).where(transaction_type:).matchable
      ids = base.joins(:lead_localities).where(lead_localities: { locality_id: search_locality_ids }).pluck(:id)
      ids | pin_lead_ids(base)
    end

    def search_locality_ids
      ids = [ locality_id ].compact
      return ids unless nearby_on?

      ids + LocalityNeighbor.where(locality_id: ids).pluck(:neighbor_locality_id)
    end

    def pin_lead_ids(base)
      return [] unless nearby_on? && listing_point && listing_city_id

      box = Geo.box(listing_point[:lat], listing_point[:lng])
      center_ids = Geo.center_locality_ids(
        city_id: listing_city_id, min_lat: box.min_lat, max_lat: box.max_lat,
        min_lng: box.min_lng, max_lng: box.max_lng
      )
      TaggedLeads.ids(box:, city_id: listing_city_id, center_ids:, lead_scope: base)
    end

    def nearby_on?
      return @nearby_on unless @nearby_on.nil?

      @nearby_on = NearbyMatching.enabled?
    end

    def listing_building
      return if property.nil?

      @listing_building ||= Building.unscoped.includes(:locality).find_by(id: property.building_id)
    end

    def listing_point
      @listing_point ||= if project
        Geo.listing_point(
          lat: project.lat, lng: project.lng,
          locality_lat: project.locality&.lat, locality_lng: project.locality&.lng
        )
      else
        Geo.listing_point(
          lat: listing_building&.lat, lng: listing_building&.lng,
          locality_lat: listing_building&.locality&.lat, locality_lng: listing_building&.locality&.lng
        )
      end
    end

    def listing_city_id
      project ? project.city_id : listing_building&.city_id
    end

    def property_type_scope(scope)
      ready_ids = PropertyType.where(code: "ready_possession").select(:id)
      if property&.for_sale?
        scope.where(property_type_id: ready_ids)
      elsif project && !PossessionMatch.ready?(project)
        scope.where.not(property_type_id: ready_ids)
      else
        scope
      end
    end

    def scored
      rows = leads
      index = HookIndex.for(rows, nearby: nearby_on?)
      rows.filter_map { |lead| serialize(lead, index) }
    end

    def serialize(lead, index)
      hooks = LeadHooks.for(lead, index:)
      decision = CandidateRank.decide(
        hooks:,
        locality_id:,
        lat: project&.lat || listing_building&.lat,
        lng: project&.lng || listing_building&.lng,
        locality_lat: project&.locality&.lat || listing_building&.locality&.lat,
        locality_lng: project&.locality&.lng || listing_building&.locality&.lng
      )
      return unless decision

      breakdown = MatchScore.for_offers(
        budget: lead.budget_amount,
        offers:,
        lead_keys: lead.typologies.map { |typology| ConfigurationKey.call(typology.name) },
        fallback_price: project&.starting_budget,
        location_points: decision.location_points
      )
      {
        kind: "lead",
        id: lead.id,
        code: lead.code,
        name: lead.display_name,
        mobile: lead.mobile,
        budget: lead.budget_amount,
        typologies: lead.typologies.map(&:name),
        localities: lead.localities.map(&:name),
        status: {
          code: lead.lead_status.code,
          name: lead.lead_status.name,
          is_dead: lead.lead_status.is_dead,
          is_booked: lead.lead_status.is_booked
        },
        score: breakdown[:score],
        score_breakdown: breakdown.slice(:location, :price, :configuration),
        matched_price: breakdown[:matched_price],
        matched_configuration: breakdown[:matched_configuration],
        mapped: mapped?(lead),
        matched_on: MatchScore.matched_on(breakdown, nearby: decision.nearby),
        distance_m: decision.distance_m,
        group: decision.group,
        near_shortlist: decision.near_shortlist,
        sort: CandidateRank.sort_key(ranking: hooks.ranking?, decision:, score: breakdown[:score], name: lead.display_name)
      }
    end

    def offers
      @offers ||= if project
        project.project_typologies.includes(:typology).map do |row|
          MatchScore::Offer.new(
            price: row.starting_price,
            name: row.typology&.name,
            key: ConfigurationKey.call(row.typology&.name)
          )
        end
      else
        [
          MatchScore::Offer.new(
            price: property.price,
            name: property.typology&.name,
            key: ConfigurationKey.call(property.typology&.name)
          )
        ]
      end
    end

    def mapped?(lead)
      if project
        lead.lead_projects.any? { |row| row.project_id == project.id && row.withdrawn_at.nil? }
      else
        lead.lead_properties.any? { |row| row.property_id == property.id }
      end
    end
  end
end
