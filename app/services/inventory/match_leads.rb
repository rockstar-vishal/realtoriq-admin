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
        .map { |row| row.except(:sort) }
    end

    private

    attr_reader :user, :project, :property

    def locality_id
      project ? project.locality_id : property&.locality_id
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
      scope = Fit.leads_for_listing(
        scope, categories: listing_categories, typology_ids_by_category: typology_ids_by_category
      )
      property_type_scope(scope)
        .includes(:typologies, :localities, :lead_projects, :lead_properties, :property_type, :lead_status)
        .to_a
    end

    def listing_categories
      property ? [ property.typology&.category ].compact : project.categories
    end

    def typology_ids_by_category
      if property
        category = property.typology&.category
        return {} if category.blank?

        { category => [ property.typology_id ] }
      else
        project.categories.index_with { |category| project.typology_ids_for(category) }
      end
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
      return [] unless nearby_on?

      if anchors_on?
        point = listing_own_pin
        return [] if point.nil?

        box = Geo.box(point[:lat], point[:lng], metres: anchor_radius + 150)
        return AnchoredLeads.ids(box:, lead_scope: base, unscoped: false)
      end
      return [] unless listing_point && listing_city_id

      box = Geo.box(listing_point[:lat], listing_point[:lng])
      center_ids = Geo.center_locality_ids(
        city_id: listing_city_id, min_lat: box.min_lat, max_lat: box.max_lat,
        min_lng: box.min_lng, max_lng: box.max_lng
      )
      TaggedLeads.ids(box:, city_id: listing_city_id, center_ids:, lead_scope: base)
    end

    def nearby_on?
      return @nearby_on unless @nearby_on.nil?

      @nearby_on = NearbyMatching.enabled? || anchors_on?
    end

    def read_anchor_switch
      return if defined?(@anchor_radius)

      @anchor_radius = AnchorMatching.pick(:radius_m)
    end

    def anchors_on?
      read_anchor_switch
      !@anchor_radius.nil?
    end

    def anchor_radius
      read_anchor_switch
      @anchor_radius
    end

    def listing_own_pin
      @listing_own_pin ||= if project
        Geo.own_pin(
          lat: project.lat, lng: project.lng,
          locality_lat: project.locality&.lat, locality_lng: project.locality&.lng,
          approximate: project.pin_approximate
        )
      elsif property
        Geo.own_pin(
          lat: property.lat, lng: property.lng,
          locality_lat: property.locality&.lat, locality_lng: property.locality&.lng,
          approximate: property.pin_approximate
        )
      end
    end

    def listing_point
      @listing_point ||= if project
        Geo.listing_point(
          lat: project.lat, lng: project.lng,
          locality_lat: project.locality&.lat, locality_lng: project.locality&.lng,
          approximate: project.pin_approximate
        )
      elsif property
        Geo.listing_point(
          lat: property.lat, lng: property.lng,
          locality_lat: property.locality&.lat, locality_lng: property.locality&.lng,
          approximate: property.pin_approximate
        )
      end
    end

    def listing_city_id
      project ? project.city_id : property&.city_id
    end

    # Land leads store a null property_type_id. `NOT IN` drops those rows,
    # so the land arm is written out instead of being left to the null.
    def property_type_scope(scope)
      if property&.for_sale?
        scope.where(<<~SQL.squish)
          leads.category = 'land'
          OR leads.property_type_id IN (SELECT id FROM property_types WHERE code = 'ready_possession')
        SQL
      elsif project && !PossessionMatch.ready?(project)
        scope.where(<<~SQL.squish)
          leads.category = 'land'
          OR leads.property_type_id NOT IN (SELECT id FROM property_types WHERE code = 'ready_possession')
        SQL
      else
        scope
      end
    end

    def scored
      rows = leads
      index = HookIndex.for(rows, nearby: nearby_on?, anchors: anchors_on?, radius_m: anchor_radius)
      rows.filter_map { |lead| serialize(lead, index) }
    end

    def serialize(lead, index)
      hooks = LeadHooks.for(lead, index:)
      decision = CandidateRank.decide(
        hooks:,
        locality_id:,
        lat: project&.lat || property&.lat,
        lng: project&.lng || property&.lng,
        locality_lat: project&.locality&.lat || property&.locality&.lat,
        locality_lng: project&.locality&.lng || property&.locality&.lng,
        round_distance: property.present? && property.firm_id != user.firm_id,
        skip_listing:,
        approximate: (project || property)&.pin_approximate
      )
      return unless decision

      chosen = offers_for(lead)
      return if chosen.empty?

      breakdown = MatchScore.for_offers(
        budget: lead.budget_amount,
        offers: chosen,
        lead_keys: lead.typologies.map { |typology| ConfigurationKey.call(typology.name) },
        fallback_price: Fit.fallback_price(lead, project),
        location_points: decision.location_points,
        fit: lead.category == "residential" ? :configuration : :area,
        bonus: Fit.pre_leased_bonus(lead, listing_for(lead)),
        lead:
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
        score_breakdown: breakdown.slice(*MatchScore::BREAKDOWN_KEYS),
        matched_price: breakdown[:matched_price],
        matched_configuration: breakdown[:matched_configuration],
        mapped: mapped?(lead),
        matched_on: MatchScore.matched_on(breakdown, nearby: decision.nearby),
        distance_m: decision.shown_distance_m,
        distance_rounded: decision.distance_rounded,
        anchor: anchor_payload(decision),
        group: decision.group,
        near_shortlist: decision.near_shortlist,
        category: lead.category,
        area_sqft: breakdown[:matched_area_sqft],
        area_unit: breakdown[:matched_area_unit],
        area_value: AreaUnits.display_quantity(breakdown[:matched_area_value]),
        pre_leased: breakdown[:matched_pre_leased] == true,
        area: {
          value: AreaUnits.display_quantity(breakdown[:matched_area_value]),
          unit: breakdown[:matched_area_unit],
          sqft: breakdown[:matched_area_sqft],
          kind: lead.category == "land" ? "plot" : "carpet"
        },
        sort: CandidateRank.sort_key(
          ranking: hooks.ranking?, decision:, score: breakdown[:score], name: lead.display_name,
          pre_leased_first: Fit.pre_leased_first?(lead, listing_for(lead)), tie: lead.id
        )
      }
    end

    def listing_for(_lead)
      property
    end

    def configuration_rows
      @configuration_rows ||= project ? project.project_typologies.includes(:typology).to_a : []
    end

    def offers_for(lead)
      if project
        configuration_rows.filter_map { |row|
          next unless Fit.row_in_scope?(lead, row.typology)

          MatchScore.offer_for_row(row)
        }
      elsif Fit.row_in_scope?(lead, property.typology)
        [ MatchScore.offer_for_property(property) ]
      else
        []
      end
    end

    def mapped?(lead)
      if project
        ids = anchors_on? ? ProjectTwins.expand([ project.id ], firm_id: user.firm_id) : [ project.id ]
        lead.lead_projects.any? { |row| ids.include?(row.project_id) && row.withdrawn_at.nil? }
      else
        lead.lead_properties.any? { |row| row.property_id == property.id }
      end
    end

    def skip_listing
      if project
        { kind: "project", ids: ProjectTwins.expand([ project.id ], firm_id: user.firm_id) }
      else
        { kind: "property", ids: [ property.id ] }
      end
    end

    def anchor_payload(decision)
      return if decision.anchor.nil?

      { kind: decision.anchor.kind, name: decision.anchor.name }
    end
  end
end
