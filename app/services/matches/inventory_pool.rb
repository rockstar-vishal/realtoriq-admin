# frozen_string_literal: true

module Matches
  # Inventory a firm's leads can be scored against, loaded once per cycle.
  # Marketplace rows are cached per locality. Own stock is always read fresh.
  # Scoring stays in MatchScore; this only gathers candidates.
  class InventoryPool
    Candidate = Struct.new(
      :kind, :id, :name, :locality_id, :marketplace, :listing_for, :ready,
      :offers, :fallback_price, :floor,
      keyword_init: true
    )
    CACHE_TTL = 1.hour
    Possession = Struct.new(:possession_on, :possession_label)

    def self.call(locality_ids:, price_cap:)
      new(locality_ids:, price_cap:).call
    end

    def initialize(locality_ids:, price_cap:)
      @locality_ids = Array(locality_ids).uniq
      @price_cap = price_cap
    end

    def call
      { projects: projects, properties: properties }
    end

    private

    attr_reader :locality_ids, :price_cap

    def projects
      return [] if locality_ids.empty?

      own_projects + marketplace_projects
    end

    def properties
      return [] if locality_ids.empty?

      own_properties + shared_properties
    end

    def own_projects
      Project.where(status: "active", source: "own", locality_id: locality_ids)
        .includes(project_typologies: :typology)
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
      Rails.cache.fetch("matches/marketplace-projects/v1/#{locality_id}", expires_in: CACHE_TTL) do
        Project.marketplace.where(locality_id:)
          .includes(project_typologies: :typology)
          .map { |project| project_payload(project) }
      end
    end

    def cached_shared_properties(locality_id)
      Rails.cache.fetch("matches/shared-properties/v1/#{locality_id}", expires_in: CACHE_TTL) do
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
        floor: marketplace ? Inventory::MatchInventory::MARKETPLACE_FLOOR : Inventory::MatchInventory::OWN_FLOOR
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
        floor: Inventory::MatchInventory::MARKETPLACE_FLOOR
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
        floor: marketplace ? Inventory::MatchInventory::MARKETPLACE_FLOOR : Inventory::MatchInventory::OWN_FLOOR
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
        floor: Inventory::MatchInventory::MARKETPLACE_FLOOR
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
