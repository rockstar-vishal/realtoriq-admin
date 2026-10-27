# frozen_string_literal: true

module Localities
  # One Geocoding API lookup. The key stays in the query string. A timeout or
  # socket error is swallowed so the request URL cannot be printed. The centre
  # job sets reraise and gets a URL-free Unavailable instead.
  class GoogleGeocoder
    ENDPOINT = "https://maps.googleapis.com/maps/api/geocode/json"
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 5
    CITY_TYPES = %w[locality administrative_area_level_2 administrative_area_level_3].freeze

    # A transport failure, with no request URL in the message.
    class Unavailable < StandardError
      def initialize
        super("Geocoding failed")
      end
    end

    def initialize(api_key, reraise: false)
      @api_key = api_key
      @reraise = reraise
    end

    def coordinates(address)
      location = first_result(geocode(address:))&.dig("geometry", "location")
      return if location.nil?

      [ location["lat"], location["lng"] ]
    end

    # administrative_area_level_1, long name. Nil when Google has no state.
    def state_from_pin(lat, lng)
      state_name(first_result(geocode(latlng: "#{lat},#{lng}")))
    end

    # Forward lookup. Accepted only when the first hit is a city or a district.
    def state_from_city(name)
      result = first_result(geocode(address: "#{name}, India"))
      return unless result && CITY_TYPES.intersect?(Array(result["types"]))

      state_name(result)
    end

    private

    attr_reader :api_key, :reraise

    def geocode(params)
      uri = URI(ENDPOINT)
      uri.query = URI.encode_www_form(params.merge(key: api_key, region: "in"))
      response = fetch(uri)
      return unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue StandardError
      raise Unavailable if reraise

      nil
    end

    def first_result(body)
      body&.dig("results", 0)
    end

    def state_name(result)
      component = Array(result&.dig("address_components")).find { |row|
        Array(row["types"]).include?("administrative_area_level_1")
      }
      component&.dig("long_name").presence
    end

    def fetch(uri)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = READ_TIMEOUT
        http.request(Net::HTTP::Get.new(uri))
      end
    end
  end
end
