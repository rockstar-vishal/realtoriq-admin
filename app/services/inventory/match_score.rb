# frozen_string_literal: true

module Inventory
  # 100-point match. Location is scored by the caller (it is the gate).
  # Price tiers do not stack. A price at or under the budget is the top tier.
  class MatchScore
    LOCATION_POINTS = 30
    CONFIG_POINTS = 20
    Offer = Struct.new(:price, :name, :key, keyword_init: true)

    def self.price_points(price, budget)
      return 0 if price.nil? || budget.nil? || budget.to_i <= 0

      amount = price.to_d
      limit = budget.to_d
      return 50 if amount <= limit * BigDecimal("1.02")
      return 30 if amount <= limit * BigDecimal("1.15")
      return 20 if amount <= limit * BigDecimal("1.25")

      0
    end

    # offers: priced and unpriced configurations. fallback_price is a project's
    # starting_budget, used only when no configuration has a price.
    def self.for_offers(budget:, offers:, lead_keys:, fallback_price: nil)
      keys = Array(lead_keys).compact_blank
      list = Array(offers)
      matched = list.select { |offer| offer.key.present? && keys.include?(offer.key) }
      priced_matched = matched.select { |offer| offer.price.to_i.positive? }
      chosen = if matched.any?
        priced_matched.any? ? best_priced(priced_matched, budget) : fallback_offer(fallback_price)
      else
        closest_priced(list, budget) || fallback_offer(fallback_price)
      end

      price_part = chosen ? price_points(chosen.price, budget) : 0
      configuration = matched.any? ? CONFIG_POINTS : 0
      configuration_name = if matched.any?
        (priced_matched.any? ? chosen&.name : matched.first&.name)
      end

      {
        location: LOCATION_POINTS,
        price: price_part,
        configuration: configuration,
        score: LOCATION_POINTS + price_part + configuration,
        matched_price: chosen&.price,
        matched_configuration: configuration_name
      }
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

    def self.matched_on(breakdown)
      reasons = [ "locality" ]
      reasons << "price" if breakdown[:price].positive?
      reasons << "configuration" if breakdown[:configuration].positive?
      reasons
    end

    private_class_method :best_priced, :closest_priced, :fallback_offer
  end
end
