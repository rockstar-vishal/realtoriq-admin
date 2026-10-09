# frozen_string_literal: true

module Localities
  # One Geocoding API lookup. The key stays in the query string. Failures are
  # swallowed so a timeout or socket error cannot print the request URL.
  class GoogleGeocoder
    ENDPOINT = "https://maps.googleapis.com/maps/api/geocode/json"
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 5

    def initialize(api_key)
      @api_key = api_key
    end

    def coordinates(address)
      uri = URI(ENDPOINT)
      uri.query = URI.encode_www_form(address:, key: api_key, region: "in")
      response = fetch(uri)
      return unless response.is_a?(Net::HTTPSuccess)

      body = JSON.parse(response.body)
      location = body.dig("results", 0, "geometry", "location")
      return if location.nil?

      [ location["lat"], location["lng"] ]
    rescue StandardError
      nil
    end

    private

    attr_reader :api_key

    def fetch(uri)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = READ_TIMEOUT
        http.request(Net::HTTP::Get.new(uri))
      end
    end
  end
end
