# frozen_string_literal: true

module Inventory
  # Projects and properties this lead could be shown. A shared preferred
  # locality is required. Marketplace rows and the firm's own active projects
  # are both listed. Nothing is copied into My Projects here.
  class MatchInventory
    LIMIT = 50
    OWN_FLOOR = 30
    MARKETPLACE_FLOOR = 50

    def initialize(lead:)
      @lead = lead
    end

    def call(query: nil)
      result(query:)[:matches]
    end

    def result(query: nil)
      rows = visible_rows
      rows = filter_query(rows, query) if query.present?
      ordered = rows.sort_by { |row| row[:sort] }
      listed = query.present? ? ordered : ordered.first(LIMIT)
      {
        matches: listed.map { |row| publish(row) },
        truncated: query.blank? && ordered.size > LIMIT,
        interest_localities: interest_localities,
        neighbor_localities: neighbor_localities
      }
    end

    private

    attr_reader :lead

    def visible_rows
      return [] if lead.unqualified? || lead.lead_status&.is_booked?
      return [] if locality_ids.empty?

      (project_rows + property_rows).select { |row| row[:score] > row[:floor] && !row[:mapped] }
    end

    def locality_ids
      hooks.search_locality_ids
    end

    def hooks
      @hooks ||= LeadHooks.for(lead)
    end

    def interest_localities
      hooks.preferred_localities.map { |locality| { id: locality.id, name: locality.name } }
    end

    def neighbor_localities
      hooks.neighbor_localities
    end

    def lead_keys
      @lead_keys ||= lead.typologies.map { |typology| ConfigurationKey.call(typology.name) }
    end

    def budget
      lead.budget_amount
    end

    def project_rows
      return [] if lead.rent?

      (own_projects + marketplace_projects).filter_map do |project|
        next unless show_project?(project)

        serialize_project(project)
      end
    end

    def show_project?(project)
      return true unless lead.ready_possession?

      PossessionMatch.ready?(project)
    end

    def own_projects
      load_projects(projects_in(Project.where(status: "active", source: "own")))
    end

    def marketplace_projects
      load_projects(projects_in(Project.marketplace))
    end

    def projects_in(scope)
      return scope.none if locality_ids.empty? && hooks.pins.empty?

      scope.where(id: project_ids(scope))
    end

    def project_ids(scope)
      ids = locality_ids.empty? ? [] : scope.where(locality_id: locality_ids).pluck(:id)
      hooks.pins.each do |pin|
        box = Geo.box(pin[:lat], pin[:lng])
        ids |= scope.where(city_id: pin[:city_id], lat: box.min_lat..box.max_lat, lng: box.min_lng..box.max_lng).pluck(:id)
        ids |= scope.where(locality_id: center_ids(pin, box)).pluck(:id)
      end
      ids
    end

    def load_projects(scope)
      scope.includes(:builder, :city, :locality, project_typologies: :typology).to_a
    end

    def property_rows
      return [] if lead.sale? && !lead.ready_possession?

      (own_properties + shared_properties).filter_map { |property| serialize_property(property) }
    end

    def own_properties
      scope = Property.where(status: "available", listing_for: lead.transaction_type)
      Property.where(id: property_ids(scope))
        .includes(:typology, building: %i[city locality])
        .to_a
    end

    def shared_properties
      return [] if Current.firm_id.blank?
      return [] if lead.firm&.review_demo? || Current.firm&.review_demo?

      scope = Property.unscoped
        .where(listed_on_marketplace: true, status: "available", listing_for: lead.transaction_type)
        .where(firm_id: Firm.marketplace_eligible.where.not(id: Current.firm_id).select(:id))
      records = Property.unscoped.where(id: property_ids(scope)).includes(:typology, :firm).to_a
      Buildings.attach(records)
      records
    end

    def property_ids(scope)
      return [] if locality_ids.empty? && hooks.pins.empty?

      joined = scope.joins("INNER JOIN buildings ON buildings.id = properties.building_id")
      ids = locality_ids.empty? ? [] : joined.where(buildings: { locality_id: locality_ids }).pluck(:id)
      hooks.pins.each do |pin|
        box = Geo.box(pin[:lat], pin[:lng])
        ids |= joined.where(buildings: { city_id: pin[:city_id] })
          .where(buildings: { lat: box.min_lat..box.max_lat, lng: box.min_lng..box.max_lng })
          .pluck(:id)
        ids |= joined.where(buildings: { locality_id: center_ids(pin, box) }).pluck(:id)
      end
      ids
    end

    def serialize_project(project)
      offers = project.project_typologies.map do |row|
        MatchScore::Offer.new(
          price: row.starting_price,
          name: row.typology&.name,
          key: ConfigurationKey.call(row.typology&.name)
        )
      end
      ranked = rank_listing(
        locality_id: project.locality_id,
        lat: project.lat, lng: project.lng,
        locality_lat: project.locality&.lat, locality_lng: project.locality&.lng,
        offers:, fallback_price: project.starting_budget, name: project.name
      )
      return unless ranked

      breakdown = ranked[:breakdown]
      marketplace = project.marketplace?
      {
        kind: "project",
        id: project.id,
        name: project.name,
        source: project.source,
        marketplace:,
        listed_by: marketplace ? project.builder&.name : nil,
        city: project.city&.name,
        locality: project.locality&.name,
        starting_budget: project.starting_budget,
        score: breakdown[:score],
        score_breakdown: breakdown.slice(:location, :price, :configuration),
        matched_price: breakdown[:matched_price],
        matched_configuration: breakdown[:matched_configuration],
        mapped: mapped_project_ids.include?(project.id),
        matched_on: MatchScore.matched_on(breakdown, nearby: ranked[:nearby]),
        distance_m: ranked[:distance_m],
        group: ranked[:group],
        near_shortlist: ranked[:near_shortlist],
        sort: ranked[:sort],
        floor: marketplace ? MARKETPLACE_FLOOR : OWN_FLOOR,
        configuration_names: project.project_typologies.filter_map { |row| row.typology&.name }
      }
    end

    def serialize_property(property)
      offers = [
        MatchScore::Offer.new(
          price: property.price,
          name: property.typology&.name,
          key: ConfigurationKey.call(property.typology&.name)
        )
      ]
      building = property.building
      ranked = rank_listing(
        locality_id: building&.locality_id,
        lat: building&.lat, lng: building&.lng,
        locality_lat: building&.locality&.lat, locality_lng: building&.locality&.lng,
        offers:, name: property.title
      )
      return unless ranked

      breakdown = ranked[:breakdown]
      shared = property.firm_id != Current.firm_id
      card = shared ? PropertyCard.for(property) : nil
      {
        kind: "property",
        id: property.id,
        name: shared ? card[:title] : property.title,
        title: shared ? card[:title] : property.title,
        listing_for: property.listing_for,
        marketplace: shared,
        listed_by: shared ? card[:firm_name] : nil,
        city: shared ? card[:city] : property.building&.city&.name,
        locality: shared ? card[:locality] : property.building&.locality&.name,
        price: property.price,
        score: breakdown[:score],
        score_breakdown: breakdown.slice(:location, :price, :configuration),
        matched_price: breakdown[:matched_price],
        matched_configuration: breakdown[:matched_configuration],
        mapped: mapped_property_ids.include?(property.id),
        matched_on: MatchScore.matched_on(breakdown, nearby: ranked[:nearby]),
        distance_m: ranked[:distance_m],
        group: ranked[:group],
        near_shortlist: ranked[:near_shortlist],
        sort: ranked[:sort],
        floor: shared ? MARKETPLACE_FLOOR : OWN_FLOOR,
        configuration_names: [ property.typology&.name ]
      }
    end

    def filter_query(rows, query)
      needle = compact_text(query)
      return rows if needle.blank?

      rows.select { |row| compact_text(search_text(row)).include?(needle) }
    end

    def search_text(row)
      [
        row[:name], row[:listed_by], row[:locality], row[:city],
        row[:matched_configuration], *Array(row[:configuration_names])
      ].compact.join(" ")
    end

    def compact_text(value)
      value.to_s.downcase.gsub(/[^a-z0-9.]/, "")
    end

    def rank_listing(locality_id:, lat:, lng:, locality_lat:, locality_lng:, offers:, name:, fallback_price: nil)
      decision = CandidateRank.decide(hooks:, locality_id:, lat:, lng:, locality_lat:, locality_lng:)
      return unless decision

      breakdown = MatchScore.for_offers(
        budget:, offers:, lead_keys:, fallback_price:, location_points: decision.location_points
      )
      {
        breakdown:,
        nearby: decision.nearby,
        distance_m: decision.distance_m,
        group: decision.group,
        near_shortlist: decision.near_shortlist,
        sort: CandidateRank.sort_key(ranking: hooks.ranking?, decision:, score: breakdown[:score], name:)
      }
    end

    def center_ids(pin, box)
      Geo.center_locality_ids(
        city_id: pin[:city_id], min_lat: box.min_lat, max_lat: box.max_lat,
        min_lng: box.min_lng, max_lng: box.max_lng
      )
    end

    def publish(row)
      row.except(:floor, :configuration_names, :sort)
    end

    def mapped_project_ids
      @mapped_project_ids ||= lead.lead_projects
        .reject { |row| row.withdrawn_at.present? }
        .map(&:project_id)
    end

    def mapped_property_ids
      @mapped_property_ids ||= lead.lead_properties.map(&:property_id)
    end
  end
end
