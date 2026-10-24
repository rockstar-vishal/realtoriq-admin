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
        neighbor_localities: neighbor_localities,
        anchors: anchor_summaries
      }
    end

    private

    attr_reader :lead

    def visible_rows
      return [] if lead.unqualified? || lead.lead_status&.is_booked?
      return [] if locality_ids.empty? && circle_empty?

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
      scope = Project.where(status: "active", source: "own")
      scope = ProjectTwins.without_listed_copies(scope) if anchor_mode?
      load_projects(projects_in(scope))
    end

    def marketplace_projects
      load_projects(projects_in(Project.marketplace))
    end

    def projects_in(scope)
      return scope.none if locality_ids.empty? && circle_empty?

      in_category = scope.where(
        id: ProjectTypology.joins(:typology).where(typologies: { category: lead.category }).select(:project_id)
      )
      in_category.where(id: project_ids(in_category))
    end

    def project_ids(scope)
      ids = locality_ids.empty? ? [] : scope.where(locality_id: locality_ids).pluck(:id)
      if anchor_mode?
        hooks.anchors.each do |anchor|
          box = Geo.box(anchor.lat, anchor.lng, metres: hooks.anchor_radius_m + 150)
          ids |= scope.where(lat: box.min_lat..box.max_lat, lng: box.min_lng..box.max_lng).pluck(:id)
        end
      else
        hooks.pins.each do |pin|
          box = Geo.box(pin[:lat], pin[:lng])
          ids |= scope.where(city_id: pin[:city_id], lat: box.min_lat..box.max_lat, lng: box.min_lng..box.max_lng).pluck(:id)
          ids |= scope.where(locality_id: center_ids(pin, box)).pluck(:id)
        end
      end
      ids
    end

    def load_projects(scope)
      scope.includes(:builder, :city, :locality, project_typologies: :typology).to_a
    end

    def property_rows
      return [] if Fit.possession_applies?(lead) && !lead.ready_possession?

      (own_properties + shared_properties).filter_map { |property| serialize_property(property) }
    end

    def own_properties
      scope = properties_in_category(Property.where(status: "available", listing_for: lead.transaction_type))
      Property.where(id: property_ids(scope))
        .includes(:typology, :city, :locality)
        .to_a
    end

    def shared_properties
      return [] if Current.firm_id.blank?
      return [] if lead.firm&.review_demo? || Current.firm&.review_demo?

      scope = Property.unscoped
        .where(listed_on_marketplace: true, status: "available", listing_for: lead.transaction_type)
        .where(firm_id: Firm.marketplace_eligible.where.not(id: Current.firm_id).select(:id))
      scope = properties_in_category(scope)
      records = Property.unscoped.where(id: property_ids(scope)).includes(:typology, :firm, :city, :locality).to_a
      records
    end

    def properties_in_category(scope)
      scoped = scope.joins(:typology).where(typologies: { category: lead.category })
      return scoped if lead.category == "residential"

      scoped.where(typology_id: lead.typology_ids)
    end

    def property_ids(scope)
      return [] if locality_ids.empty? && circle_empty?

      ids = locality_ids.empty? ? [] : scope.where(locality_id: locality_ids).pluck(:id)
      if anchor_mode?
        hooks.anchors.each do |anchor|
          box = Geo.box(anchor.lat, anchor.lng, metres: hooks.anchor_radius_m + 150)
          ids |= scope.where(lat: box.min_lat..box.max_lat, lng: box.min_lng..box.max_lng).pluck(:id)
        end
      else
        hooks.pins.each do |pin|
          box = Geo.box(pin[:lat], pin[:lng])
          ids |= scope.where(city_id: pin[:city_id], lat: box.min_lat..box.max_lat, lng: box.min_lng..box.max_lng).pluck(:id)
          ids |= scope.where(locality_id: center_ids(pin, box)).pluck(:id)
        end
      end
      ids
    end

    def serialize_project(project)
      rows = in_scope_rows(project)
      return if rows.empty?

      offers = rows.map { |row| MatchScore.offer_for_row(row) }
      ranked = rank_listing(
        locality_id: project.locality_id,
        lat: project.lat, lng: project.lng,
        locality_lat: project.locality&.lat, locality_lng: project.locality&.lng,
        offers:, fallback_price: Fit.fallback_price(lead, project), name: project.name, listing: project
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
        starting_budget: shown_starting_budget(project),
        score: breakdown[:score],
        score_breakdown: breakdown.slice(*MatchScore::BREAKDOWN_KEYS),
        matched_price: breakdown[:matched_price],
        matched_configuration: breakdown[:matched_configuration],
        mapped: mapped_project_ids.include?(project.id),
        matched_on: MatchScore.matched_on(breakdown, nearby: ranked[:nearby]),
        distance_m: ranked[:distance_m],
        distance_rounded: ranked[:distance_rounded],
        anchor: ranked[:anchor],
        group: ranked[:group],
        near_shortlist: ranked[:near_shortlist],
        sort: ranked[:sort],
        floor: marketplace ? MARKETPLACE_FLOOR : OWN_FLOOR,
        configuration_names: rows.map(&:display_name)
      }.merge(area_fields(breakdown))
    end

    def in_scope_rows(project)
      project.project_typologies.select { |row| Fit.row_in_scope?(lead, row.typology) }
    end

    def shown_starting_budget(project)
      return project.starting_budget unless project.categories.size > 1

      project.starting_price_for(lead.category)
    end

    def serialize_property(property)
      return unless Fit.row_in_scope?(lead, property.typology)

      offers = [ MatchScore.offer_for_property(property) ]
      ranked = rank_listing(
        locality_id: property.locality_id,
        lat: property.lat, lng: property.lng,
        locality_lat: property.locality&.lat, locality_lng: property.locality&.lng,
        offers:, name: property.title, listing: property
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
        city: shared ? card[:city] : property.city&.name,
        locality: shared ? card[:locality] : property.locality&.name,
        price: property.price,
        score: breakdown[:score],
        score_breakdown: breakdown.slice(*MatchScore::BREAKDOWN_KEYS),
        matched_price: breakdown[:matched_price],
        matched_configuration: breakdown[:matched_configuration],
        mapped: mapped_property_ids.include?(property.id),
        matched_on: MatchScore.matched_on(breakdown, nearby: ranked[:nearby]),
        distance_m: ranked[:distance_m],
        distance_rounded: ranked[:distance_rounded],
        anchor: ranked[:anchor],
        group: ranked[:group],
        near_shortlist: ranked[:near_shortlist],
        sort: ranked[:sort],
        floor: shared ? MARKETPLACE_FLOOR : OWN_FLOOR,
        configuration_names: [ property.typology&.name ]
      }.merge(area_fields(breakdown))
    end

    def area_fields(breakdown)
      value = AreaUnits.display_quantity(breakdown[:matched_area_value])
      {
        category: breakdown[:matched_category] || lead.category,
        area_sqft: breakdown[:matched_area_sqft],
        area_unit: breakdown[:matched_area_unit],
        area_value: value,
        pre_leased: breakdown[:matched_pre_leased] == true,
        area: {
          value:,
          unit: breakdown[:matched_area_unit],
          sqft: breakdown[:matched_area_sqft],
          kind: breakdown[:matched_category] == "land" ? "plot" : "carpet"
        }
      }
    end

    # A query that is present but compacts to nothing ("-", "@") is a search
    # with no needle. Returning every row would also skip the cap in #result.
    def filter_query(rows, query)
      needle = compact_text(query)
      return [] if needle.blank?

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

    def rank_listing(locality_id:, lat:, lng:, locality_lat:, locality_lng:, offers:, name:, listing:, fallback_price: nil)
      decision = CandidateRank.decide(
        hooks:, locality_id:, lat:, lng:, locality_lat:, locality_lng:,
        round_distance: listing.is_a?(Property) && listing.firm_id != Current.firm_id
      )
      return unless decision

      breakdown = MatchScore.for_offers(
        budget:, offers:, lead_keys:, fallback_price:, location_points: decision.location_points,
        fit: score_fit, bonus: Fit.pre_leased_bonus(lead, listing), lead:
      )
      {
        breakdown:,
        nearby: decision.nearby,
        distance_m: decision.shown_distance_m,
        distance_rounded: decision.distance_rounded,
        anchor: anchor_payload(decision),
        group: decision.group,
        near_shortlist: decision.near_shortlist,
        sort: CandidateRank.sort_key(
          ranking: hooks.ranking?, decision:, score: breakdown[:score], name:,
          pre_leased_first: Fit.pre_leased_first?(lead, listing), tie: listing.id
        )
      }
    end

    def score_fit
      lead.category == "residential" ? :configuration : :area
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
      @mapped_project_ids ||= begin
        ids = lead.lead_projects.reject { |row| row.withdrawn_at.present? }.map(&:project_id)
        if anchor_mode?
          ids = ProjectTwins.expand(ids, firm_id: lead.firm_id)
          ids |= ProjectTwins.expand(hooks.visited_project_ids, firm_id: lead.firm_id)
        end
        ids
      end
    end

    def mapped_property_ids
      @mapped_property_ids ||= begin
        ids = lead.lead_properties.map(&:property_id)
        ids |= hooks.visited_property_ids if anchor_mode?
        ids
      end
    end

    def anchor_mode?
      hooks.anchor_mode?
    end

    def circle_empty?
      anchor_mode? ? hooks.anchors.empty? : hooks.pins.empty?
    end

    def anchor_summaries
      return [] unless anchor_mode?

      hooks.anchors.map { |anchor|
        { kind: anchor.kind, name: anchor.name, listing_kind: anchor.listing_kind, listing_id: anchor.listing_id }
      }
    end

    def anchor_payload(decision)
      return if decision.anchor.nil?

      { kind: decision.anchor.kind, name: decision.anchor.name }
    end
  end
end
