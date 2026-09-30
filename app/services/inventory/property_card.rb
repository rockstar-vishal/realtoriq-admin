# frozen_string_literal: true

module Inventory
  # Fields another firm may see on a shared listing. The building name,
  # address, and pin stay on the owning firm's own screens.
  class PropertyCard
    def self.for(property)
      building = building_for(property)
      {
        title: title_for(property, building),
        locality: building&.locality&.name,
        city: building&.city&.name,
        firm_name: property.firm&.name
      }
    end

    def self.building_for(property)
      if property.firm_id.present? && property.firm_id != Current.firm_id
        Building.unscoped.includes(:locality, :city).find_by(id: property.building_id)
      else
        property.building
      end
    end

    def self.title_for(property, building = building_for(property))
      [ property.typology&.name, building&.locality&.name ].compact_blank.join(" in ").presence ||
        (property.firm_id == Current.firm_id ? building&.name : nil) ||
        "Listing"
    end
  end
end
