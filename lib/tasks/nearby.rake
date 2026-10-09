# frozen_string_literal: true

namespace :localities do
  desc "Fill blank locality centers from the Geocoding API. Does not turn nearby matching on."
  task geocode: :environment do
    api_key = ENV["GOOGLE_GEOCODING_API_KEY"]
    abort "GOOGLE_GEOCODING_API_KEY is missing" if api_key.blank?

    Localities::GeocodeCenters.call(client: Localities::GoogleGeocoder.new(api_key))
  end
end

namespace :matches do
  desc "Rebuild neighbor pairs, refresh digests without notifying, and turn nearby matching on."
  task nearby_enable: :environment do
    Matches::EnableNearby.call
  end
end
