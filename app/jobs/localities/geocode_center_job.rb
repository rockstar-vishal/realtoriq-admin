# frozen_string_literal: true

module Localities
  # Fills one blank locality centre after a LaunchIQ share creates it.
  # A hand-set centre is left alone. Neighbour pairs come from Locality's
  # after_commit. Match digests are not rewritten here.
  class GeocodeCenterJob < ApplicationJob
    queue_as :default

    # A timeout raises a URL-free error. One retry, then it stays blank.
    retry_on GoogleGeocoder::Unavailable, wait: 5.minutes, attempts: 2

    def perform(locality_id)
      locality = Locality.includes(:city).find_by(id: locality_id)
      return if locality.nil? || locality.lat.present?

      key = ENV["GOOGLE_GEOCODING_API_KEY"].presence
      if key.blank?
        Rails.logger.info("[geocode] key missing, #{locality.display_name} left blank")
        return
      end

      GeocodeCenters.fill_one(locality, client: GoogleGeocoder.new(key, reraise: true))
    end
  end
end
