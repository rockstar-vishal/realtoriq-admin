# frozen_string_literal: true

module Inventory
  # Fields another firm may see on a shared listing. The building name,
  # address, and pin stay on the owning firm's own screens.
  class PropertyCard
    def self.for(property)
      {
        title: title_for(property),
        locality: property.locality&.name,
        city: property.city&.name,
        firm_name: property.firm&.name
      }
    end

    def self.title_for(property)
      [ property.typology&.name, property.locality&.name ].compact_blank.join(" in ").presence ||
        (property.firm_id == Current.firm_id ? property.building_name : nil) ||
        "Listing"
    end
  end
end
