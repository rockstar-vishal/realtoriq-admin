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
      MarketplaceLeadMatches.new(property:).scored_rows.filter_map { |row| row[:firm_id] }
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
