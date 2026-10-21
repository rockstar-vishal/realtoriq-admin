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
      scope = ready_or_land(scope) if property.for_sale?
      scope = Fit.leads_for_listing(
        scope, categories: listing_categories, typology_ids_by_category: typology_ids_by_category
      )
      scope.includes(:typologies, :property_type).distinct.to_a
    end

    def ready_or_land(scope)
      ready_ids = PropertyType.where(code: "ready_possession").select(:id)
      scope.where(category: "land").or(scope.where(property_type_id: ready_ids))
    end

    def listing_categories
      [ property.typology&.category ].compact
    end

    def typology_ids_by_category
      category = property.typology&.category
      return {} if category.blank?

      { category => [ property.typology_id ] }
    end

    def score_for(lead)
      return 0 unless Fit.row_in_scope?(lead, property.typology)

      MatchScore.for_offers(
        budget: lead.budget_amount,
        offers:,
        lead_keys: lead.typologies.map { |typology| ConfigurationKey.call(typology.name) },
        fit: lead.category == "residential" ? :configuration : :area,
        bonus: Fit.pre_leased_bonus(lead, property),
        lead:
      )[:score]
    end

    def offers
      @offers ||= [ MatchScore.offer_for_property(property) ]
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
