# frozen_string_literal: true

module Matches
  # Inventory a firm's leads can be scored against, loaded once per cycle.
  # Marketplace rows are cached per locality. Own stock is always read fresh.
  # Scoring stays in MatchScore; this only gathers candidates.
  class InventoryPool
    Candidate = Struct.new(
      :kind, :id, :name, :locality_id, :marketplace, :listing_for, :ready,
      :offers, :fallback_price, :floor,
      :lat, :lng, :locality_lat, :locality_lng,
      keyword_init: true
    )
    CACHE_TTL = 1.hour
    Possession = Struct.new(:possession_on, :possession_label)

    def self.call(locality_ids:, price_cap:, boxes: [])
      new(locality_ids:, price_cap:, boxes:).call
    end

    def initialize(locality_ids:, price_cap:, boxes: [])
      @locality_ids = Array(locality_ids).uniq
      @price_cap = price_cap
      @boxes = boxes
    end

    def call
      { projects: projects, properties: properties }
    end

    private

    attr_reader :locality_ids, :price_cap, :boxes

    def projects
      return box_projects if locality_ids.empty?

      (own_projects + marketplace_projects + box_projects).uniq { |item| item.id }
    end

    def properties
      return box_properties if locality_ids.empty?

      (own_properties + shared_properties + box_properties).uniq { |item| item.id }
    end

    def own_projects
      Project.where(status: "active", source: "own", locality_id: locality_ids)
        .includes(:locality, project_typologies: :typology)
        .map { |project| project_candidate(project, marketplace: false) }
    end

    def marketplace_projects
      locality_ids.flat_map { |locality_id| cached_marketplace_projects(locality_id) }
        .filter_map { |row| marketplace_project_candidate(row) }
    end

    def own_properties
      Property.where(status: "available")
        .joins(:building)
        .where(buildings: { locality_id: locality_ids })
        .includes(:typology, building: :locality)
        .map { |property| property_candidate(property, marketplace: false) }
    end

    def shared_properties
      return [] if Current.firm_id.blank? || Current.firm&.review_demo?

      eligible = Firm.marketplace_eligible.where.not(id: Current.firm_id).pluck(:id).to_set
      locality_ids.flat_map { |locality_id| cached_shared_properties(locality_id) }
        .filter_map { |row| shared_property_candidate(row, eligible) }
    end

    def cached_marketplace_projects(locality_id)
      Rails.cache.fetch("matches/marketplace-projects/v2/#{locality_id}", expires_in: CACHE_TTL) do
        Project.marketplace.where(locality_id:)
          .includes(:locality, project_typologies: :typology)
          .map { |project| project_payload(project) }
      end
    end

    def cached_shared_properties(locality_id)
      Rails.cache.fetch("matches/shared-properties/v2/#{locality_id}", expires_in: CACHE_TTL) do
        records = Property.unscoped
          .where(listed_on_marketplace: true, status: "available")
          .joins("INNER JOIN buildings ON buildings.id = properties.building_id")
          .where(buildings: { locality_id: })
          .includes(:typology, :firm)
          .to_a
        buildings = Building.unscoped.where(id: records.map(&:building_id)).includes(:locality).index_by(&:id)
        records.map { |property| property_payload(property, buildings[property.building_id]) }
      end
    end

    def box_projects
      return [] if boxes.empty?

      own_scope = Project.where(status: "active", source: "own")
      own = projects_from(own_scope, in_boxes(own_scope))
        .map { |project| project_candidate(project, marketplace: false) }
      market = projects_from(Project.marketplace, in_boxes(Project.marketplace))
        .filter_map { |project| boxed_marketplace_project(project) }
      own + market
    end

    def boxed_marketplace_project(project)
      candidate = project_candidate(project, marketplace: true)
      candidate if marketplace_price_ok?(candidate.offers, candidate.fallback_price)
    end

    def box_properties
      return [] if boxes.empty?

      near = buildings_near
      own = Property.where(status: "available", building_id: near)
        .includes(:typology, building: :locality)
        .map { |property| property_candidate(property, marketplace: false) }
      eligible = Firm.marketplace_eligible.where.not(id: Current.firm_id).select(:id)
      shared_scope = Property.unscoped.where(
        listed_on_marketplace: true, status: "available", building_id: near, firm_id: eligible
      )
      shared_scope = shared_scope.where(price: ..price_cap) if price_cap
      records = shared_scope.includes(:typology, :firm).to_a
      Inventory::Buildings.attach(records)
      shared = records.map { |property| property_candidate(property, marketplace: true) }
      own + shared
    end

    def buildings_near
      table = Building.arel_table
      boxes_pred = boxes.map { |box|
        table[:city_id].eq(box[:city_id])
          .and(table[:lat].between(box[:min_lat]..box[:max_lat]))
          .and(table[:lng].between(box[:min_lng]..box[:max_lng]))
      }.reduce { |combined, predicate| combined.or(predicate) }
      predicate = boxes_pred
      if center_locality_ids.any?
        centers = table[:locality_id].in(center_locality_ids)
        predicate = predicate.or(centers)
      end
      Building.unscoped.where(predicate).select(:id)
    end

    def projects_from(scope, boxed)
      ids = boxed.pluck(:id)
      ids |= scope.where(locality_id: center_locality_ids).pluck(:id) if center_locality_ids.any?
      scope.where(id: ids).includes(:locality, project_typologies: :typology)
    end

    def center_locality_ids
      @center_locality_ids ||= boxes.flat_map { |box|
        Inventory::Geo.center_locality_ids(
          city_id: box[:city_id], min_lat: box[:min_lat], max_lat: box[:max_lat],
          min_lng: box[:min_lng], max_lng: box[:max_lng]
        )
      }.uniq
    end

    def in_boxes(scope)
      clauses = boxes.map { |box|
        scope.where(city_id: box[:city_id], lat: box[:min_lat]..box[:max_lat], lng: box[:min_lng]..box[:max_lng])
      }
      clauses.reduce { |combined, clause| combined.or(clause) }
    end

    def project_candidate(project, marketplace:)
      Candidate.new(
        kind: "project",
        id: project.id,
        name: project.name,
        locality_id: project.locality_id,
        marketplace:,
        listing_for: nil,
        ready: Inventory::PossessionMatch.ready?(project),
        offers: offers_for(project),
        fallback_price: project.starting_budget,
        floor: marketplace ? Inventory::MatchInventory::MARKETPLACE_FLOOR : Inventory::MatchInventory::OWN_FLOOR,
        lat: project.lat, lng: project.lng,
        locality_lat: project.locality&.lat, locality_lng: project.locality&.lng
      )
    end

    def marketplace_project_candidate(row)
      offers = offer_structs(row["offers"])
      return unless marketplace_price_ok?(offers, row["starting_budget"])

      snapshot = Possession.new(parse_date(row["possession_on"]), row["possession_label"])
      Candidate.new(
        kind: "project",
        id: row["id"],
        name: row["name"],
        locality_id: row["locality_id"],
        marketplace: true,
        listing_for: nil,
        ready: Inventory::PossessionMatch.ready?(snapshot),
        offers:,
        fallback_price: row["starting_budget"],
        floor: Inventory::MatchInventory::MARKETPLACE_FLOOR,
        lat: row["lat"], lng: row["lng"],
        locality_lat: row["locality_lat"], locality_lng: row["locality_lng"]
      )
    end

    def property_candidate(property, marketplace:)
      Candidate.new(
        kind: "property",
        id: property.id,
        name: property_title(property, shared: marketplace),
        locality_id: property.building&.locality_id,
        marketplace:,
        listing_for: property.listing_for,
        ready: nil,
        offers: [
          Inventory::MatchScore::Offer.new(
            price: property.price,
            name: property.typology&.name,
            key: Inventory::ConfigurationKey.call(property.typology&.name)
          )
        ],
        fallback_price: nil,
        floor: marketplace ? Inventory::MatchInventory::MARKETPLACE_FLOOR : Inventory::MatchInventory::OWN_FLOOR,
        lat: property.building&.lat, lng: property.building&.lng,
        locality_lat: property.building&.locality&.lat, locality_lng: property.building&.locality&.lng
      )
    end

    def shared_property_candidate(row, eligible)
      return unless eligible.include?(row["firm_id"])
      return if price_cap && row["price"].to_i > price_cap

      Candidate.new(
        kind: "property",
        id: row["id"],
        name: row["name"],
        locality_id: row["locality_id"],
        marketplace: true,
        listing_for: row["listing_for"],
        ready: nil,
        offers: offer_structs(row["offers"]),
        fallback_price: nil,
        floor: Inventory::MatchInventory::MARKETPLACE_FLOOR,
        lat: row["lat"], lng: row["lng"],
        locality_lat: row["locality_lat"], locality_lng: row["locality_lng"]
      )
    end

    # Keep a catalog project the live scorer could still clear. An unpriced
    # matching configuration is scored against starting_budget, not against
    # the other configurations' prices. Dropping on those other prices would
    # hide a match the lead screen still shows.
    def marketplace_price_ok?(offers, fallback)
      return true if price_cap.nil?

      priced = offers.filter_map { |offer| offer.price.to_i if offer.price.to_i.positive? }
      fallback_price = fallback.to_i
      return true if priced.any? { |price| price <= price_cap }
      return false unless fallback_price.positive? && fallback_price <= price_cap

      priced.empty? || offers.any? { |offer| offer.price.to_i <= 0 }
    end

    def project_payload(project)
      {
        "id" => project.id,
        "name" => project.name,
        "locality_id" => project.locality_id,
        "possession_on" => project.possession_on&.iso8601,
        "possession_label" => project.possession_label,
        "starting_budget" => project.starting_budget,
        "lat" => project.lat, "lng" => project.lng,
        "locality_lat" => project.locality&.lat, "locality_lng" => project.locality&.lng,
        "offers" => offers_for(project).map { |offer| { "price" => offer.price, "name" => offer.name, "key" => offer.key } }
      }
    end

    def property_payload(property, building)
      {
        "id" => property.id,
        "firm_id" => property.firm_id,
        "name" => property_title(property, building, shared: true),
        "locality_id" => building&.locality_id,
        "listing_for" => property.listing_for,
        "price" => property.price,
        "lat" => building&.lat, "lng" => building&.lng,
        "locality_lat" => building&.locality&.lat, "locality_lng" => building&.locality&.lng,
        "offers" => [
          {
            "price" => property.price,
            "name" => property.typology&.name,
            "key" => Inventory::ConfigurationKey.call(property.typology&.name)
          }
        ]
      }
    end

    def offers_for(project)
      project.project_typologies.map do |row|
        Inventory::MatchScore::Offer.new(
          price: row.starting_price,
          name: row.typology&.name,
          key: Inventory::ConfigurationKey.call(row.typology&.name)
        )
      end
    end

    def offer_structs(rows)
      Array(rows).map do |row|
        Inventory::MatchScore::Offer.new(price: row["price"], name: row["name"], key: row["key"])
      end
    end

    def property_title(property, building = property.building, shared:)
      [ property.typology&.name, building&.locality&.name ].compact_blank.join(" in ").presence ||
        (shared ? "Listing" : building&.name) ||
        "Listing"
    end

    def parse_date(value)
      return if value.blank?

      Date.iso8601(value)
    end
  end
end
