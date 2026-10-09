# frozen_string_literal: true

module Inventory
  # Lead ids that mapped a project or property whose pin, or whose locality
  # center, falls in the box. Inventory ids stay in SQL. A city-wide pluck
  # would pull every private listing id into memory.
  module TaggedLeads
    module_function

    def ids(box:, city_id:, center_ids:, lead_scope:, unscoped: false)
      projects = unscoped ? LeadProject.unscoped : LeadProject
      properties = unscoped ? LeadProperty.unscoped : LeadProperty
      found = lead_ids(projects.where(withdrawn_at: nil), :project_id, projects_in_box(box, city_id), lead_scope)
      if center_ids.any?
        found |= lead_ids(
          projects.where(withdrawn_at: nil), :project_id,
          Project.unscoped.where(locality_id: center_ids).select(:id), lead_scope
        )
      end
      found |= lead_ids(properties, :property_id, properties_for(buildings_in_box(box, city_id)), lead_scope)
      if center_ids.any?
        found |= lead_ids(
          properties, :property_id,
          properties_for(Building.unscoped.where(locality_id: center_ids).select(:id)), lead_scope
        )
      end
      found
    end

    def lead_ids(relation, column, record_ids, lead_scope)
      relation.where(column => record_ids).where(lead_id: lead_scope.select(:id)).distinct.pluck(:lead_id)
    end

    def projects_in_box(box, city_id)
      Project.unscoped.where(
        city_id:, lat: box.min_lat..box.max_lat, lng: box.min_lng..box.max_lng
      ).select(:id)
    end

    def buildings_in_box(box, city_id)
      Building.unscoped.where(
        city_id:, lat: box.min_lat..box.max_lat, lng: box.min_lng..box.max_lng
      ).select(:id)
    end

    def properties_for(buildings)
      Property.unscoped.where(building_id: buildings).select(:id)
    end
    private_class_method :lead_ids, :projects_in_box, :buildings_in_box, :properties_for
  end
end
