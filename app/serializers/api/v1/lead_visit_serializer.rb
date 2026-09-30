# frozen_string_literal: true

module Api
  module V1
    module LeadVisitSerializer
      def self.call(visit)
        {
          id: visit.id,
          visited_on: visit.visited_on,
          visited_at: visit.visited_at,
          notes: visit.notes,
          user: visit.user && { id: visit.user_id, name: visit.user.name },
          projects: visit.projects.map { |project|
            { id: project.id, name: project.name, starting_budget: project.starting_budget }
          },
          properties: visit.properties.map { |property|
            shared = property.firm_id != visit.firm_id
            card = shared ? Inventory::PropertyCard.for(property) : nil
            {
              id: property.id,
              title: shared ? card[:title] : property.title,
              price: property.price,
              listing_for: property.listing_for,
              building: shared ? nil : property.building && { name: property.building.name }
            }
          },
          created_at: visit.created_at
        }
      end
    end
  end
end
