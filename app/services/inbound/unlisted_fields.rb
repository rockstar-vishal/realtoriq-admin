# frozen_string_literal: true

module Inbound
  # Budget, city, locality and configuration for a call that names no listing.
  # City names are unique per state, so two cities with the same name are refused
  # rather than guessed.
  class UnlistedFields
    Result = Struct.new(:ok?, :error, :phone, :budget, :city, :locality, :typology, :transaction_type,
      keyword_init: true)

    def self.call(payload, transaction_type:)
      new(payload, transaction_type:).call
    end

    def initialize(payload, transaction_type:)
      @payload = payload
      @asked_type = transaction_type
    end

    def call
      phone = indian_mobile
      return failure("Phone must be a 10-digit mobile number.") if phone.nil?

      budget = whole_rupees
      return failure(budget) if budget.is_a?(String)

      city = find_city
      return failure(city) if city.is_a?(String)

      locality = find_locality(city)
      return failure(locality) if locality.is_a?(String)

      typology = find_typology
      return failure(typology) if typology.is_a?(String)

      type = resolve_type
      return failure("Say whether this is a sale or a rent.") if type.nil?

      Result.new(ok?: true, phone:, budget:, city:, locality:, typology:, transaction_type: type)
    end

    private

    attr_reader :payload, :asked_type

    def failure(error) = Result.new(ok?: false, error:)

    def squeeze(value) = value.to_s.strip.gsub(/\s+/, " ")

    def indian_mobile
      raw = payload["mobile"].to_s
      return if raw.length > 32

      phone = Phone.normalise(raw)
      phone if phone&.match?(/\A\+91\d{10}\z/)
    end

    def whole_rupees
      text = payload["budget"].to_s.strip
      return "Type the budget in rupees, for example 12000000." unless text.match?(/\A\d{1,15}\z/)

      amount = Integer(text, 10)
      return "Type the budget in rupees, for example 12000000." unless amount.positive?

      amount
    end

    def find_city
      name = squeeze(payload["city"])
      return "Send the city." if name.blank?
      return "That city name is too long." if name.length > 255

      cities = City.where("lower(name) = ?", name.downcase).to_a
      return "We don't have a city named #{name}." if cities.empty?
      return "More than one city is named #{name}." if cities.many?

      cities.first
    end

    def find_locality(city)
      name = squeeze(payload["locality"])
      return "Send the locality." if name.blank?
      return "That locality name is too long." if name.length > 255

      locality = Locality.where(city_id: city.id).where("lower(name) = ?", name.downcase).first
      return "We don't have #{name} in #{city.name}." if locality.nil?

      locality
    end

    def find_typology
      name = squeeze(payload["configuration"])
      return "Send the configuration, for example 2 BHK." if name.blank?
      return "That configuration name is too long." if name.length > 255

      typology = Typology.where("lower(name) = ?", name.downcase).first
      return "We don't have a configuration named #{name}." if typology.nil?

      typology
    end

    def resolve_type
      return "sale" if asked_type == "sale"
      return asked_type if %w[sale rent].include?(asked_type)

      value = payload["transaction_type"].to_s.strip.downcase
      return value if %w[sale rent].include?(value)

      nil
    end
  end
end
