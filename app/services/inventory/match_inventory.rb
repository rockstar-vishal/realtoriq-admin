# frozen_string_literal: true

module Inventory
  # Projects and properties this lead could be shown. A shared preferred
  # locality is required. Marketplace rows and the firm's own active projects
  # are both listed. Nothing is copied into My Projects here.
  class MatchInventory
    LIMIT = 50

    def initialize(lead:)
      @lead = lead
    end

    def call
      return [] if lead.lead_status&.is_dead?
      return [] if locality_ids.empty?

      (project_rows + property_rows)
        .sort_by { |row| [ -row[:score], row[:name].to_s.downcase ] }
        .first(LIMIT)
    end

    private

    attr_reader :lead

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

      projects = own_projects + marketplace_projects
      projects.map { |project| serialize_project(project) }
    end

    def own_projects
      load_projects(Project.where(status: "active", source: "own", locality_id: locality_ids))
    end

    def marketplace_projects
      load_projects(Project.marketplace.where(locality_id: locality_ids))
    end

    def load_projects(scope)
      scope.includes(:city, :locality, project_typologies: :typology).to_a
    end

    def property_rows
      Property.where(status: "available", listing_for: lead.transaction_type)
        .joins(:building)
        .where(buildings: { locality_id: locality_ids })
        .includes(:typology, building: %i[city locality])
        .map { |property| serialize_property(property) }
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
      {
        kind: "project",
        id: project.id,
        name: project.name,
        source: project.source,
        city: project.city&.name,
        locality: project.locality&.name,
        starting_budget: project.starting_budget,
        score: breakdown[:score],
        score_breakdown: breakdown.slice(:location, :price, :configuration),
        matched_price: breakdown[:matched_price],
        matched_configuration: breakdown[:matched_configuration],
        mapped: mapped_project_ids.include?(project.id),
        matched_on: MatchScore.matched_on(breakdown)
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
      {
        kind: "property",
        id: property.id,
        name: property.title,
        title: property.title,
        listing_for: property.listing_for,
        city: property.building&.city&.name,
        locality: property.building&.locality&.name,
        price: property.price,
        score: breakdown[:score],
        score_breakdown: breakdown.slice(:location, :price, :configuration),
        matched_price: breakdown[:matched_price],
        matched_configuration: breakdown[:matched_configuration],
        mapped: mapped_property_ids.include?(property.id),
        matched_on: MatchScore.matched_on(breakdown)
      }
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
