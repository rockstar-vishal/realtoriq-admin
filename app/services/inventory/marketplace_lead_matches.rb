# frozen_string_literal: true

module Inventory
  # Other firms' leads that clear the marketplace score floor on this property.
  # The client is not named. Location is the shared locality, and configuration
  # is the lead's typology names.
  class MarketplaceLeadMatches
    LIMIT = MatchLeads::LIMIT

    def initialize(property:)
      @property = property
    end

    def call
      return [] unless property.listed_on_marketplace? && property.available?
      return [] if locality_id.blank?

      candidates.filter_map { |lead| row(lead) if score_for(lead) > MatchInventory::MARKETPLACE_FLOOR }
        .sort_by { |row| row[:firm_name].to_s.downcase }
        .first(LIMIT)
    end

    private

    attr_reader :property

    def locality_id
      property.building&.locality_id
    end

    def candidates
      scope = Lead.unscoped
        .where.not(firm_id: property.firm_id)
        .where(transaction_type: property.listing_for)
        .joins(:lead_status)
        .where(lead_statuses: { is_dead: false })
        .joins(:lead_localities)
        .where(lead_localities: { locality_id: })
        .includes(:firm, :typologies)
        .distinct
      scope = scope.joins(:property_type).where(property_types: { code: "ready_possession" }) if property.for_sale?
      scope.to_a
    end

    def score_for(lead)
      MatchScore.for_offers(
        budget: lead.budget_amount,
        offers:,
        lead_keys: lead.typologies.map { |typology| ConfigurationKey.call(typology.name) }
      )[:score]
    end

    def offers
      @offers ||= [
        MatchScore::Offer.new(
          price: property.price,
          name: property.typology&.name,
          key: ConfigurationKey.call(property.typology&.name)
        )
      ]
    end

    def row(lead)
      {
        firm_name: lead.firm&.name,
        localities: [ property.building.locality&.name ].compact,
        configurations: lead.typologies.map(&:name).sort,
        marketplace: true
      }
    end
  end
end
