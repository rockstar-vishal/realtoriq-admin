# frozen_string_literal: true

module Inventory
  # Lead ids that might sit inside one anchor circle. A superset: the place,
  # any shortlist, or any visit whose listing pin falls in the box. LeadAnchors
  # and CandidateRank decide which of those are real anchors.
  module AnchoredLeads
    module_function

    def ids(box:, lead_scope:, unscoped: false)
      projects = unscoped ? LeadProject.unscoped : LeadProject
      properties = unscoped ? LeadProperty.unscoped : LeadProperty
      visits = unscoped ? LeadVisit.unscoped : LeadVisit
      visit_projects = unscoped ? LeadVisitProject.unscoped : LeadVisitProject
      visit_properties = unscoped ? LeadVisitProperty.unscoped : LeadVisitProperty
      scope_ids = lead_scope.select(:id)
      project_ids = projects_in_box(box)
      property_ids = properties_in_box(box)

      found = lead_scope.where(
        near_lat: box.min_lat..box.max_lat, near_lng: box.min_lng..box.max_lng
      ).pluck(:id)
      found |= projects.where(withdrawn_at: nil, project_id: project_ids, lead_id: scope_ids).distinct.pluck(:lead_id)
      found |= properties.where(property_id: property_ids, lead_id: scope_ids).distinct.pluck(:lead_id)
      found |= visits.where(lead_id: scope_ids, id: visit_projects.where(project_id: project_ids).select(:lead_visit_id))
        .distinct.pluck(:lead_id)
      found |= visits.where(lead_id: scope_ids, id: visit_properties.where(property_id: property_ids).select(:lead_visit_id))
        .distinct.pluck(:lead_id)
      found
    end

    def projects_in_box(box)
      Project.unscoped.where(lat: box.min_lat..box.max_lat, lng: box.min_lng..box.max_lng).select(:id)
    end

    def properties_in_box(box)
      Property.unscoped.where(lat: box.min_lat..box.max_lat, lng: box.min_lng..box.max_lng).select(:id)
    end
    private_class_method :projects_in_box, :properties_in_box
  end
end
