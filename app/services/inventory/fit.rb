# frozen_string_literal: true

module Inventory
  # Category, area and pre-leased rules shared by every matching path.
  # A blank area scores 0: own stock is shown only above 30, and a locality
  # match alone is 30, so any points for a blank would list every listing
  # in the locality.
  module Fit
    Ref = Data.define(:id, :category)
    INNER_LOW = BigDecimal("0.9")
    INNER_HIGH = BigDecimal("1.1")
    OUTER_LOW = BigDecimal("0.75")
    OUTER_HIGH = BigDecimal("1.25")
    PRE_LEASED_POINTS = 10

    class PriceSource
      def initialize(categories:, starting_prices:, starting_budget:)
        @categories = Array(categories)
        @starting_prices = starting_prices || {}
        @starting_budget = starting_budget
      end

      attr_reader :categories, :starting_budget

      def starting_price_for(category)
        amount = @starting_prices[category] || @starting_prices[category.to_s]
        amount if amount.to_i.positive?
      end
    end

    module_function

    def possession_applies?(lead)
      lead.sale? && lead.category != "land"
    end

    def row_in_scope?(lead, typology)
      return false if typology.nil? || typology.category != lead.category
      return true if lead.category == "residential"

      typology_ids_for(lead).include?(typology.id)
    end

    def area_points(lead, area_sqft)
      return 0 unless lead.category == "commercial" || lead.category == "land"
      return 0 if lead.area_min_sqft.nil? && lead.area_max_sqft.nil?
      return 0 if area_sqft.nil? || area_sqft.to_i <= 0

      area = area_sqft.to_d
      low = (lead.area_min_sqft || 0).to_d
      high = lead.area_max_sqft&.to_d
      return 20 if covers?(area, low * INNER_LOW, high && (high * INNER_HIGH))
      return 10 if covers?(area, low * OUTER_LOW, high && (high * OUTER_HIGH))

      0
    end

    def pre_leased_bonus(lead, listing)
      pre_leased_first?(lead, listing) ? PRE_LEASED_POINTS : 0
    end

    def pre_leased_first?(lead, listing)
      return false unless lead.prefers_pre_leased
      return false if listing.nil? || !listing.respond_to?(:pre_leased)

      listing.pre_leased == true
    end

    def fallback_price(lead, project)
      return if project.nil?

      if project.categories.size > 1
        project.starting_price_for(lead.category)
      else
        project.starting_budget
      end
    end

    # Commercial and land leads must have chosen the listing's configuration.
    # Residential stays a score, not a filter. One relation per category,
    # combined with OR of subqueries, so a project is not repeated.
    def leads_for_listing(scope, categories:, typology_ids_by_category:)
      parts = Array(categories).filter_map { |category|
        next if category.blank?

        relation = scope.where(category:)
        next relation if category == "residential"

        ids = Array(typology_ids_by_category[category])
        relation.where(id: LeadTypology.where(typology_id: ids).select(:lead_id))
      }
      return scope.none if parts.empty?

      parts.reduce { |combined, part| combined.or(part) }
    end

    def covers?(area, low, high)
      area >= low && (high.nil? || area <= high)
    end
    private_class_method :covers?

    def typology_ids_for(lead)
      if lead.association(:typologies).loaded?
        lead.typologies.map(&:id)
      else
        lead.typology_ids
      end
    end
    private_class_method :typology_ids_for
  end
end
