# frozen_string_literal: true

module Inventory
  # 100-point match. Location is scored by the caller (it is the gate).
  # Price tiers do not stack. A price at or under the budget is the top tier.
  # Residential configuration scoring is the previous algorithm. Commercial
  # and land put area points in its place, then a pre-leased bonus, capped at 100.
  class MatchScore
    LOCATION_POINTS = 30
    NEARBY_POINTS = 20
    CONFIG_POINTS = 20
    # Between the 30 and 20 price tiers, so a listing within budget still ranks above.
    NO_BUDGET_POINTS = 25
    BREAKDOWN_KEYS = %i[location price fit configuration area bonus].freeze
    Offer = Struct.new(
      :price, :name, :key, :area_sqft, :area_value, :area_unit, :pre_leased, :category, :typology_id,
      keyword_init: true
    )

    def self.price_points(price, budget)
      return NO_BUDGET_POINTS if unbudgeted?(budget)
      return 0 if price.nil?

      amount = price.to_d
      limit = budget.to_d
      return 50 if amount <= limit * BigDecimal("1.02")
      return 30 if amount <= limit * BigDecimal("1.15")
      return 20 if amount <= limit * BigDecimal("1.25")

      0
    end

    def self.offer_for_row(row)
      typology = row.typology
      Offer.new(
        price: row.starting_price,
        name: row.display_name,
        key: ConfigurationKey.call(typology&.name),
        area_sqft: row.starting_carpet_sqft,
        area_value: row.area_value,
        area_unit: row.area_unit,
        pre_leased: false,
        category: typology&.category,
        typology_id: row.typology_id
      )
    end

    def self.offer_for_property(property)
      typology = property.typology
      Offer.new(
        price: property.price,
        name: typology&.name,
        key: ConfigurationKey.call(typology&.name),
        area_sqft: property.carpet_area_sqft,
        area_value: property.area_value,
        area_unit: property.area_unit,
        pre_leased: property.pre_leased,
        category: typology&.category,
        typology_id: property.typology_id
      )
    end

    # offers: priced and unpriced configurations. fallback_price is used only
    # when no configuration has a price. For a single-category project that
    # is still starting_budget. fit is :configuration or :area.
    def self.for_offers(budget:, offers:, lead_keys:, fallback_price: nil, location_points: LOCATION_POINTS,
      fit: :configuration, bonus: 0, lead: nil)
      parts = if fit == :area
        area_parts(budget:, offers:, fallback_price:, lead:)
      else
        configuration_parts(budget:, offers:, lead_keys:, fallback_price:)
      end
      location = location_points.to_i
      bonus_points = bonus.to_i
      fit_points = parts[:fit]
      {
        location:,
        price: parts[:price],
        fit: fit_points,
        configuration: fit == :area ? nil : fit_points,
        area: fit == :area ? fit_points : nil,
        bonus: bonus_points,
        unbudgeted: parts[:unbudgeted] == true,
        score: [ location + parts[:price] + fit_points + bonus_points, 100 ].min,
        matched_price: parts[:matched_price],
        matched_configuration: parts[:matched_configuration],
        matched_area_sqft: parts[:area_sqft],
        matched_area_value: parts[:area_value],
        matched_area_unit: parts[:area_unit],
        matched_pre_leased: parts[:pre_leased] == true,
        matched_category: parts[:category]
      }
    end

    def self.matched_on(breakdown, nearby: false)
      reasons = [ nearby ? "nearby" : "locality" ]
      reasons << "price" if breakdown[:price].to_i.positive? && !breakdown[:unbudgeted]
      reasons << "configuration" if breakdown[:configuration].to_i.positive?
      reasons << "area" if breakdown[:area].to_i == 20
      reasons << "pre_leased" if breakdown[:bonus].to_i.positive?
      reasons
    end

    def self.configuration_parts(budget:, offers:, lead_keys:, fallback_price:)
      keys = Array(lead_keys).compact_blank
      list = Array(offers)
      matched = list.select { |offer| offer.key.present? && keys.include?(offer.key) }
      priced_matched = matched.select { |offer| offer.price.to_i.positive? }
      chosen = if matched.any?
        priced_matched.any? ? best_priced(priced_matched, budget) : fallback_offer(fallback_price)
      else
        closest_priced(list, budget) || fallback_offer(fallback_price)
      end

      price_part = price_points(chosen&.price, budget)
      configuration = matched.any? ? CONFIG_POINTS : 0
      configuration_name = if matched.any?
        (priced_matched.any? ? chosen&.name : matched.first&.name)
      end
      source = matched.any? && priced_matched.empty? ? matched.first : chosen
      part_from(
        source, fit: configuration, price: price_part, matched_price: chosen&.price,
        name: configuration_name, unbudgeted: unbudgeted?(budget)
      )
    end

    # fallback_price stands in only when nothing in the list has a price, the
    # same rule as configuration_parts. An unpriced offer beside a priced one
    # scores 0. Borrowing the project price there would award points for a
    # configuration the lead did not choose.
    def self.area_parts(budget:, offers:, fallback_price:, lead:)
      list = Array(offers)
      borrowed = list.any? { |offer| priced?(offer) } ? nil : positive_price(fallback_price)
      if list.empty?
        chosen = fallback_offer(borrowed)
        return part_from(
          chosen, fit: 0, price: price_points(chosen&.price, budget), matched_price: chosen&.price,
          name: nil, unbudgeted: unbudgeted?(budget)
        )
      end

      best = list.max_by { |offer| area_rank(offer, budget, lead, borrowed) }
      price = priced?(best) ? best.price : borrowed
      part_from(
        best,
        fit: lead ? Fit.area_points(lead, best.area_sqft) : 0,
        price: price_points(price, budget),
        matched_price: price,
        name: best.name,
        unbudgeted: unbudgeted?(budget)
      )
    end

    def self.area_rank(offer, budget, lead, borrowed_price)
      price = priced?(offer) ? offer.price : borrowed_price
      points = price_points(price, budget)
      area = lead ? Fit.area_points(lead, offer.area_sqft) : 0
      amount = price.to_i
      target = budget.to_i
      [ points + area, points, area, -(amount - target).abs, -amount ]
    end

    def self.part_from(source, fit:, price:, matched_price:, name:, unbudgeted: false)
      {
        fit:,
        price:,
        unbudgeted:,
        matched_price:,
        matched_configuration: name,
        area_sqft: source&.area_sqft,
        area_value: source&.area_value,
        area_unit: source&.area_unit,
        pre_leased: source&.pre_leased == true,
        category: source&.category
      }
    end

    def self.priced?(offer)
      offer.price.to_i.positive?
    end

    def self.positive_price(price)
      price if price.to_i.positive?
    end

    def self.best_priced(offers, budget)
      target = budget.to_i
      offers.max_by do |offer|
        [ price_points(offer.price, budget), -(offer.price - target).abs, -offer.price ]
      end
    end

    def self.closest_priced(offers, budget)
      priced = offers.select { |offer| offer.price.to_i.positive? }
      return if priced.empty?

      target = budget.to_i
      priced.min_by { |offer| [ (offer.price - target).abs, offer.price ] }
    end

    def self.fallback_offer(price)
      return if price.to_i <= 0

      Offer.new(price: price.to_i, name: nil, key: nil)
    end

    def self.unbudgeted?(budget)
      budget.nil? || budget.to_i <= 0
    end

    private_class_method :configuration_parts, :area_parts, :area_rank, :part_from, :priced?, :positive_price,
      :best_priced, :closest_priced, :fallback_offer, :unbudgeted?
  end
end
