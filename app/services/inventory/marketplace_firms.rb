# frozen_string_literal: true

module Inventory
  # Other firms the listing broker may contact about this property.
  # A firm name and its phone lines only. No lead is serialized.
  class MarketplaceFirms
    def initialize(property:)
      @property = property
    end

    def call
      return [] unless property.listed_on_marketplace? && property.available?
      return [] if Current.firm&.review_demo? || property.firm&.review_demo?

      firms = Firm.marketplace_eligible.where(id: firm_ids).order(:name).to_a
      channels = ContactChannel.unscoped.where(firm_id: firms.map(&:id)).group_by(&:firm_id)
      firms.map { |firm| payload(firm, channels[firm.id] || []) }
    end

    private

    attr_reader :property

    def firm_ids
      (score_firm_ids + mapped_firm_ids).uniq
    end

    def mapped_firm_ids
      LeadProperty.unscoped
        .where(property_id: property.id, firm_id: Firm.marketplace_eligible.select(:id))
        .where.not(firm_id: property.firm_id)
        .distinct
        .pluck(:firm_id)
    end

    def score_firm_ids
      candidates.filter_map { |lead| lead.firm_id if score_for(lead) > MatchInventory::MARKETPLACE_FLOOR }
    end

    def candidates
      scope = Lead.unscoped
        .where(firm_id: Firm.marketplace_eligible.select(:id))
        .where.not(firm_id: property.firm_id)
        .where(transaction_type: property.listing_for)
        .matchable
        .joins(:lead_localities)
        .where(lead_localities: { locality_id: property.building&.locality_id })
        .includes(:typologies, :property_type)
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

    def payload(firm, channels)
      {
        id: firm.id,
        name: firm.name,
        mobile: channel_value(channels, "mobile"),
        whatsapp: channel_value(channels, "whatsapp")
      }
    end

    def channel_value(channels, kind)
      channels.find { |channel| channel.kind == kind }&.value
    end
  end
end
