# frozen_string_literal: true

module Inventory
  # Other active firms' shared, available listings. The building name,
  # address, and description are not searchable and are not returned.
  class MarketplaceListings
    def initialize(query:)
      @query = query.to_s
    end

    def scope
      return Property.unscoped.none if Current.firm_id.blank?

      relation = Property.unscoped
        .where(listed_on_marketplace: true, status: "available")
        .where.not(firm_id: Current.firm_id)
        .joins("INNER JOIN firms ON firms.id = properties.firm_id")
        .where(firms: { status: "active" })
        .joins("INNER JOIN buildings ON buildings.id = properties.building_id")
        .joins("INNER JOIN localities ON localities.id = buildings.locality_id")
        .joins("INNER JOIN cities ON cities.id = buildings.city_id")
        .joins("INNER JOIN typologies ON typologies.id = properties.typology_id")
        .includes(:typology, :firm)

      compact = compact_query
      return relation.none if @query.strip.present? && compact.blank?

      relation = search(relation, compact) if compact.present?
      relation.order("properties.created_at DESC, properties.id DESC")
    end

    private

    def compact_query
      @query.downcase.gsub(/[^a-z0-9.]/, "")
    end

    def search(relation, compact)
      pattern = "%#{Property.sanitize_sql_like(compact)}%"
      relation.where(<<~SQL.squish, q: pattern)
        regexp_replace(lower(COALESCE(firms.name, '')), '[^a-z0-9.]', '', 'g') LIKE :q
        OR regexp_replace(lower(COALESCE(localities.name, '')), '[^a-z0-9.]', '', 'g') LIKE :q
        OR regexp_replace(lower(COALESCE(cities.name, '')), '[^a-z0-9.]', '', 'g') LIKE :q
        OR regexp_replace(lower(COALESCE(typologies.name, '')), '[^a-z0-9.]', '', 'g') LIKE :q
      SQL
    end
  end
end
