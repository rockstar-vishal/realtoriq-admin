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
      return [] if locality_id.blank?
      return [] if project && !project.active?
      return [] if property && !property.available?

      scored
        .select { |row| row[:score] > floor }
        .sort_by { |row| [ -row[:score], row[:name].to_s.downcase ] }
        .first(LIMIT)
    end

    private

    attr_reader :user, :project, :property

    def locality_id
      project ? project.locality_id : property.building&.locality_id
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
        .joins(:lead_localities)
        .where(lead_localities: { locality_id: })
        .includes(:typologies, :localities, :lead_projects, :lead_properties, :property_type, :lead_status)
        .distinct
      property_type_scope(scope).to_a
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
      leads.map { |lead| serialize(lead) }
    end

    def serialize(lead)
      breakdown = MatchScore.for_offers(
        budget: lead.budget_amount,
        offers:,
        lead_keys: lead.typologies.map { |typology| ConfigurationKey.call(typology.name) },
        fallback_price: project&.starting_budget
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
        matched_on: MatchScore.matched_on(breakdown)
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
