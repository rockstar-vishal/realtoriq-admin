# frozen_string_literal: true

module Inventory
  # Other firms' leads that clear the marketplace score floor on this property.
  # The client is not named. `firm_id` matches `marketplace_firms`, because
  # firm names are not unique. `code` is that firm's own lead code. Location
  # is the shared locality, and configuration is the lead's typology names.
  class MarketplaceLeadMatches
    LIMIT = MatchLeads::LIMIT

    def initialize(property:)
      @property = property
    end

    def call
      return [] unless property.listed_on_marketplace? && property.available?
      return [] if locality_id.blank?
      return [] if Current.firm&.review_demo? || property.firm&.review_demo?

      scored.filter_map { |score, lead| [ score, row(lead) ] if score > MatchInventory::MARKETPLACE_FLOOR }
        .sort_by { |score, row| [ -score, row[:firm_name].to_s.downcase, row[:code].to_s ] }
        .first(LIMIT)
        .map(&:last)
    end

    private

    attr_reader :property

    def locality_id
      property.building&.locality_id
    end

    def candidates
      scope = Lead.unscoped
        .where(firm_id: Firm.marketplace_eligible.select(:id))
        .where.not(firm_id: property.firm_id)
        .where(transaction_type: property.listing_for)
        .matchable
        .joins(:lead_localities)
        .where(lead_localities: { locality_id: })
        .includes(:firm, :typologies)
        .distinct
      scope = scope.joins(:property_type).where(property_types: { code: "ready_possession" }) if property.for_sale?
      scope.to_a
    end

    def scored
      candidates.map { |lead| [ score_for(lead), lead ] }
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
        firm_id: lead.firm_id,
        firm_name: lead.firm&.name,
        code: lead.code,
        localities: [ property.building.locality&.name ].compact,
        configurations: lead.typologies.map(&:name).sort,
        marketplace: true
      }
    end
  end
end
