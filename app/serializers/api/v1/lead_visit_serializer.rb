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
          projects: visit.projects.map { |project| { id: project.id, name: project.name } },
          properties: visit.properties.map { |property| { id: property.id, title: property.title } },
          created_at: visit.created_at
        }
      end
    end
  end
end
