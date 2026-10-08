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
      ordered = rows.sort_by { |row| [ -row[:score], row[:name].to_s.downcase ] }
      if query.present?
        { matches: ordered.map { |row| publish(row) }, truncated: false }
      else
        { matches: ordered.first(LIMIT).map { |row| publish(row) }, truncated: ordered.size > LIMIT }
      end
    end

    private

    attr_reader :lead

    def visible_rows
      return [] if lead.unqualified? || lead.lead_status&.is_booked?
      return [] if locality_ids.empty?

      (project_rows + property_rows).select { |row| row[:score] > row[:floor] && !row[:mapped] }
    end

    def locality_ids
      @locality_ids ||= lead.locality_ids
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
      load_projects(Project.where(status: "active", source: "own", locality_id: locality_ids))
    end

    def marketplace_projects
      load_projects(Project.marketplace.where(locality_id: locality_ids))
    end

    def load_projects(scope)
      scope.includes(:builder, :city, :locality, project_typologies: :typology).to_a
    end

    def property_rows
      return [] if lead.sale? && !lead.ready_possession?

      (own_properties + shared_properties).map { |property| serialize_property(property) }
    end

    def own_properties
      Property.where(status: "available", listing_for: lead.transaction_type)
        .joins(:building)
        .where(buildings: { locality_id: locality_ids })
        .includes(:typology, building: %i[city locality])
        .to_a
    end

    def shared_properties
      return [] if Current.firm_id.blank?
      return [] if lead.firm&.review_demo? || Current.firm&.review_demo?

      records = Property.unscoped
        .where(listed_on_marketplace: true, status: "available", listing_for: lead.transaction_type)
        .where(firm_id: Firm.marketplace_eligible.where.not(id: Current.firm_id).select(:id))
        .joins("INNER JOIN buildings ON buildings.id = properties.building_id")
        .where(buildings: { locality_id: locality_ids })
        .includes(:typology, :firm)
        .to_a
      preload_buildings(records)
      records
    end

    def preload_buildings(records)
      return if records.empty?

      ActiveRecord::Associations::Preloader.new(
        records:,
        associations: { building: %i[locality city] },
        scope: Building.unscoped
      ).call
    end

    def serialize_project(project)
      offers = project.project_typologies.map do |row|
        MatchScore::Offer.new(
          price: row.starting_price,
          name: row.typology&.name,
          key: ConfigurationKey.call(row.typology&.name)
        )
      end
      breakdown = MatchScore.for_offers(
        budget:, offers:, lead_keys:, fallback_price: project.starting_budget
      )
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
        matched_on: MatchScore.matched_on(breakdown),
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
      breakdown = MatchScore.for_offers(budget:, offers:, lead_keys:)
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
        matched_on: MatchScore.matched_on(breakdown),
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

    def publish(row)
      row.except(:floor, :configuration_names)
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
