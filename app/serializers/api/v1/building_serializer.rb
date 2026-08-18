# frozen_string_literal: true

module Api
  module V1
    module BuildingSerializer
      def self.call(building)
        {
          id: building.id,
          name: building.name,
          display_name: building.display_name,
          city: building.city && { id: building.city_id, name: building.city.name },
          locality: building.locality && { id: building.locality_id, name: building.locality.name },
          address: building.address,
          lat: building.lat&.to_f,
          lng: building.lng&.to_f,
          google_place_id: building.google_place_id,
          has_pool: building.has_pool,
          has_gym: building.has_gym,
          property_count: building.properties.size,
          created_at: building.created_at
        }
      end
    end
  end
end
