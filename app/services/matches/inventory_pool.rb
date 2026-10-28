# frozen_string_literal: true

module Matches
  # Inventory a firm's leads can be scored against, loaded once per cycle.
  # Marketplace rows are cached per locality. Own stock is always read fresh.
  # Scoring stays in MatchScore; this only gathers candidates.
  class InventoryPool
    Candidate = Struct.new(
      :kind, :id, :name, :locality_id, :marketplace, :listing_for, :ready,
      :offers, :fallback_price, :floor,
      :lat, :lng, :locality_lat, :locality_lng, :approximate,
      :categories, :starting_prices,
      keyword_init: true
    ) do
      def pre_leased
        Array(offers).any? { |offer| offer.pre_leased }
      end

      def price_source
        return unless kind == "project"

        Inventory::Fit::PriceSource.new(
          categories: Array(categories),
          starting_prices: starting_prices || {},
          starting_budget: fallback_price
        )
      end
    end
    CACHE_TTL = 1.hour
    Possession = Struct.new(:possession_on, :possession_label)

    def self.call(locality_ids:, price_cap:, boxes: [], centers: true, hide_listed_copies: false)
      new(locality_ids:, price_cap:, boxes:, centers:, hide_listed_copies:).call
    end

    # The shared-properties fetch uses this same key. A listing that leaves
    # the set has to delete it, or other firms keep matching it for the hour.
    # There is no batch key: one load fills these per-locality entries, and
    # this delete is what the next pass reads.
    def self.forget_shared_properties(locality_id)
      return if locality_id.blank?

      Rails.cache.delete(shared_properties_cache_key(locality_id))
    end

    def self.shared_properties_cache_key(locality_id)
      "matches/shared-properties/v5/#{locality_id}"
    end

    def initialize(locality_ids:, price_cap:, boxes: [], centers: true, hide_listed_copies: false)
      @locality_ids = Array(locality_ids).uniq
      @price_cap = price_cap
      @boxes = boxes
      @centers = centers
      @hide_listed_copies = hide_listed_copies
    end

    def call
      { projects: projects, properties: properties }
    end

    private

    attr_reader :locality_ids, :price_cap, :boxes, :centers, :hide_listed_copies

    def projects
      return box_projects if locality_ids.empty?

      (own_projects + marketplace_projects + box_projects).uniq { |item| item.id }
    end

    def properties
      return box_properties if locality_ids.empty?

      (own_properties + shared_properties + box_properties).uniq { |item| item.id }
    end

    def own_projects
      scope = Project.where(status: "active", source: "own", locality_id: locality_ids)
      scope = Inventory::ProjectTwins.without_listed_copies(scope) if hide_listed_copies
      scope.includes(:locality, project_typologies: :typology)
        .map { |project| project_candidate(project, marketplace: false) }
    end

    def marketplace_projects
      batched_rows(locality_ids, method(:marketplace_projects_cache_key)) { |missing|
        Project.marketplace.where(locality_id: missing)
          .includes(:locality, project_typologies: :typology)
          .group_by(&:locality_id)
          .transform_values { |projects| projects.map { |project| project_payload(project) } }
      }.filter_map { |row| marketplace_project_candidate(row) }
    end

    def own_properties
      Property.where(status: "available")
        .where(locality_id: locality_ids)
        .includes(:typology, :locality)
        .map { |property| property_candidate(property, marketplace: false) }
    end

    def shared_properties
      return [] if Current.firm_id.blank? || Current.firm&.review_demo?

      eligible = Firm.marketplace_eligible.where.not(id: Current.firm_id).pluck(:id).to_set
      batched_rows(locality_ids, self.class.method(:shared_properties_cache_key)) { |missing|
        Property.unscoped
          .where(listed_on_marketplace: true, status: "available", locality_id: missing)
          .includes(:typology, :firm, :locality)
          .group_by(&:locality_id)
          .transform_values { |properties| properties.map { |property| property_payload(property) } }
      }.filter_map { |row| shared_property_candidate(row, eligible) }
    end

    # Read every locality already cached. One query fills the rest, and each
    # locality — including one with no rows — is written back under its own key.
    def batched_rows(ids, key_for)
      return [] if ids.empty?

      keys = ids.to_h { |id| [ key_for.call(id), id ] }
      cached = Rails.cache.read_multi(*keys.keys)
      missing = []
      by_id = {}
      ids.each do |id|
        key = key_for.call(id)
        if cached.key?(key)
          by_id[id] = Array(cached[key])
        else
          missing << id
        end
      end
      if missing.any?
        loaded = yield(missing)
        missing.each do |id|
          payload = Array(loaded[id])
          Rails.cache.write(key_for.call(id), payload, expires_in: CACHE_TTL)
          by_id[id] = payload
        end
      end
      ids.flat_map { |id| by_id[id] }
    end

    def marketplace_projects_cache_key(locality_id)
      "matches/marketplace-projects/v4/#{locality_id}"
    end

    def box_projects
      return [] if boxes.empty?

      own_scope = Project.where(status: "active", source: "own")
      own_scope = Inventory::ProjectTwins.without_listed_copies(own_scope) if hide_listed_copies
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

      near = properties_near
      own = Property.where(status: "available", id: near)
        .includes(:typology, :locality)
        .map { |property| property_candidate(property, marketplace: false) }
      eligible = Firm.marketplace_eligible.where.not(id: Current.firm_id).select(:id)
      shared_scope = Property.unscoped.where(
        listed_on_marketplace: true, status: "available", id: near, firm_id: eligible
      )
      shared_scope = shared_scope.where(price: ..price_cap) if price_cap
      shared = shared_scope.includes(:typology, :firm, :locality).map { |property|
        property_candidate(property, marketplace: true)
      }
      own + shared
    end

    def properties_near
      table = Property.arel_table
      boxes_pred = boxes.map { |box|
        located = table[:lat].between(box[:min_lat]..box[:max_lat])
          .and(table[:lng].between(box[:min_lng]..box[:max_lng]))
        box[:city_id].present? ? table[:city_id].eq(box[:city_id]).and(located) : located
      }.reduce { |combined, predicate| combined.or(predicate) }
      predicate = boxes_pred
      if center_locality_ids.any?
        centers = table[:locality_id].in(center_locality_ids)
        predicate = predicate.or(centers)
      end
      Property.unscoped.where(predicate).select(:id)
    end

    def projects_from(scope, boxed)
      ids = boxed.pluck(:id)
      ids |= scope.where(locality_id: center_locality_ids).pluck(:id) if center_locality_ids.any?
      scope.where(id: ids).includes(:locality, project_typologies: :typology)
    end

    def center_locality_ids
      return [] unless centers

      @center_locality_ids ||= boxes.flat_map { |box|
        Inventory::Geo.center_locality_ids(
          city_id: box[:city_id], min_lat: box[:min_lat], max_lat: box[:max_lat],
          min_lng: box[:min_lng], max_lng: box[:max_lng]
        )
      }.uniq
    end

    def in_boxes(scope)
      clauses = boxes.map { |box| boxed_scope(scope, box) }
      clauses.reduce { |combined, clause| combined.or(clause) }
    end

    def boxed_scope(scope, box)
      located = scope.where(lat: box[:min_lat]..box[:max_lat], lng: box[:min_lng]..box[:max_lng])
      return located if box[:city_id].blank?

      located.where(city_id: box[:city_id])
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
        categories: project.categories,
        starting_prices: project.starting_prices,
        floor: marketplace ? Inventory::MatchInventory::MARKETPLACE_FLOOR : Inventory::MatchInventory::OWN_FLOOR,
        lat: project.lat, lng: project.lng,
        locality_lat: project.locality&.lat, locality_lng: project.locality&.lng,
        approximate: project.pin_approximate
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
        categories: row["categories"],
        starting_prices: row["starting_prices"],
        floor: Inventory::MatchInventory::MARKETPLACE_FLOOR,
        lat: row["lat"], lng: row["lng"],
        locality_lat: row["locality_lat"], locality_lng: row["locality_lng"],
        approximate: row["pin_approximate"] == true
      )
    end

    def property_candidate(property, marketplace:)
      Candidate.new(
        kind: "property",
        id: property.id,
        name: property_title(property, shared: marketplace),
        locality_id: property.locality_id,
        marketplace:,
        listing_for: property.listing_for,
        ready: nil,
        offers: [ Inventory::MatchScore.offer_for_property(property) ],
        fallback_price: nil,
        floor: marketplace ? Inventory::MatchInventory::MARKETPLACE_FLOOR : Inventory::MatchInventory::OWN_FLOOR,
        lat: property.lat, lng: property.lng,
        locality_lat: property.locality&.lat, locality_lng: property.locality&.lng,
        approximate: property.pin_approximate
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
        locality_lat: row["locality_lat"], locality_lng: row["locality_lng"],
        approximate: row["pin_approximate"] == true
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
        "categories" => project.categories,
        "starting_prices" => project.starting_prices,
        "lat" => project.lat, "lng" => project.lng,
        "locality_lat" => project.locality&.lat, "locality_lng" => project.locality&.lng,
        "pin_approximate" => project.pin_approximate,
        "offers" => offers_for(project).map { |offer| offer_payload(offer) }
      }
    end

    def property_payload(property)
      {
        "id" => property.id,
        "firm_id" => property.firm_id,
        "name" => property_title(property, shared: true),
        "locality_id" => property.locality_id,
        "listing_for" => property.listing_for,
        "price" => property.price,
        "lat" => property.lat, "lng" => property.lng,
        "locality_lat" => property.locality&.lat, "locality_lng" => property.locality&.lng,
        "pin_approximate" => property.pin_approximate,
        "offers" => [ offer_payload(Inventory::MatchScore.offer_for_property(property)) ]
      }
    end

    def offers_for(project)
      project.project_typologies.map { |row| Inventory::MatchScore.offer_for_row(row) }
    end

    def offer_payload(offer)
      {
        "price" => offer.price,
        "name" => offer.name,
        "key" => offer.key,
        "area_sqft" => offer.area_sqft,
        "area_value" => offer.area_value,
        "area_unit" => offer.area_unit,
        "pre_leased" => offer.pre_leased,
        "category" => offer.category,
        "typology_id" => offer.typology_id
      }
    end

    def offer_structs(rows)
      Array(rows).map do |row|
        Inventory::MatchScore::Offer.new(
          price: row["price"], name: row["name"], key: row["key"],
          area_sqft: row["area_sqft"], area_value: row["area_value"], area_unit: row["area_unit"],
          pre_leased: row["pre_leased"], category: row["category"], typology_id: row["typology_id"]
        )
      end
    end

    def property_title(property, shared:)
      [ property.typology&.name, property.locality&.name ].compact_blank.join(" in ").presence ||
        (shared ? nil : property.building_name).presence ||
        "Listing"
    end

    def parse_date(value)
      return if value.blank?

      Date.iso8601(value)
    end
  end
end
