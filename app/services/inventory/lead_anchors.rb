# frozen_string_literal: true

module Inventory
  # Up to three places a lead cares about: the place on the lead, then visited
  # listings newest first, then shortlisted listings newest first. Mappings and
  # visits are read unscoped, the same way HookIndex loads pins, so another
  # firm's marketplace lead is not anchorless. One batch is a fixed set of
  # queries, whatever its size.
  class LeadAnchors
    Anchor = Data.define(:lat, :lng, :kind, :name, :listing_kind, :listing_id, :other_firm)
    Result = Struct.new(:anchors, :visited_project_ids, :visited_property_ids) do
      def [](lead_id)
        anchors[lead_id] || []
      end
    end

    def self.for(leads)
      new(leads).call
    end

    def initialize(leads)
      @leads = Array(leads)
      @by_id = @leads.index_by(&:id)
    end

    def call
      load
      anchors = {}
      visited_projects = {}
      visited_properties = {}
      @by_id.each_key do |lead_id|
        anchors[lead_id] = pick(lead_id)
        visited_projects[lead_id] = @visit_projects.fetch(lead_id, []).uniq
        visited_properties[lead_id] = @visit_properties.fetch(lead_id, []).uniq
      end
      Result.new(anchors, visited_projects, visited_properties)
    end

    private

    def load
      ids = @by_id.keys
      @withdrawn = {}
      @shortlist = {}
      @visit_projects = {}
      @visit_properties = {}
      @visit_order = {}
      project_ids = []
      property_ids = []

      LeadProject.unscoped.where(lead_id: ids).pluck(:lead_id, :project_id, :withdrawn_at, :created_at).each do |lead_id, project_id, withdrawn_at, created_at|
        if withdrawn_at.present?
          (@withdrawn[lead_id] ||= []) << project_id
        else
          (@shortlist[lead_id] ||= []) << [ "project", project_id, created_at ]
          project_ids << project_id
        end
      end
      LeadProperty.unscoped.where(lead_id: ids).pluck(:lead_id, :property_id, :created_at).each do |lead_id, property_id, created_at|
        (@shortlist[lead_id] ||= []) << [ "property", property_id, created_at ]
        property_ids << property_id
      end

      visits = LeadVisit.unscoped.where(lead_id: ids).order(visited_at: :desc, created_at: :desc)
        .pluck(:id, :lead_id, :visited_at, :created_at)
      visit_ids = visits.map(&:first)
      projects_by_visit = {}
      LeadVisitProject.unscoped.where(lead_visit_id: visit_ids).order(:created_at, :id)
        .pluck(:lead_visit_id, :project_id).each do |visit_id, project_id|
          (projects_by_visit[visit_id] ||= []) << project_id
          project_ids << project_id
        end
      properties_by_visit = {}
      LeadVisitProperty.unscoped.where(lead_visit_id: visit_ids).order(:created_at, :id)
        .pluck(:lead_visit_id, :property_id).each do |visit_id, property_id|
          (properties_by_visit[visit_id] ||= []) << property_id
          property_ids << property_id
        end
      visits.each do |visit_id, lead_id, _visited_at, _created_at|
        list = @visit_order[lead_id] ||= []
        Array(projects_by_visit[visit_id]).each do |project_id|
          list << [ "project", project_id ]
          (@visit_projects[lead_id] ||= []) << project_id
        end
        Array(properties_by_visit[visit_id]).each do |property_id|
          list << [ "property", property_id ]
          (@visit_properties[lead_id] ||= []) << property_id
        end
      end

      @projects = project_ids.empty? ? {} : Project.unscoped.where(id: project_ids.uniq).includes(:locality).index_by(&:id)
      @properties = if property_ids.empty?
        {}
      else
        Property.unscoped.where(id: property_ids.uniq).includes(:typology, :locality, :firm, :city).index_by(&:id)
      end
    end

    def pick(lead_id)
      lead = @by_id[lead_id]
      chosen = []
      seen_listings = {}
      seen_coords = {}
      place = placed_anchor(lead)
      if place
        chosen << place
        seen_coords[coord_key(place.lat, place.lng)] = true
      end
      Array(@visit_order[lead_id]).each do |kind, listing_id|
        break if chosen.size >= Geo::MAX_ANCHORS

        consider(chosen, seen_listings, seen_coords, lead, kind, listing_id, "visited")
      end
      shortlist = Array(@shortlist[lead_id]).sort_by { |kind, listing_id, created_at| [ -created_at.to_f, kind, listing_id.to_s ] }
      shortlist.each do |kind, listing_id, _created_at|
        break if chosen.size >= Geo::MAX_ANCHORS

        consider(chosen, seen_listings, seen_coords, lead, kind, listing_id, "shortlisted")
      end
      chosen
    end

    def consider(chosen, seen_listings, seen_coords, lead, kind, listing_id, anchor_kind)
      key = [ kind, listing_id ]
      return if seen_listings[key]
      return if kind == "project" && Array(@withdrawn[lead.id]).include?(listing_id)

      anchor = listing_anchor(lead, kind, listing_id, anchor_kind)
      return unless anchor

      coord = coord_key(anchor.lat, anchor.lng)
      return if seen_coords[coord]

      seen_listings[key] = true
      seen_coords[coord] = true
      chosen << anchor
    end

    def placed_anchor(lead)
      return if lead.near_lat.blank? || lead.near_lng.blank?
      return unless Geo.inside_maharashtra?(lead.near_lat, lead.near_lng)

      Anchor.new(
        lat: lead.near_lat.to_f, lng: lead.near_lng.to_f, kind: "placed", name: lead.near_label,
        listing_kind: nil, listing_id: nil, other_firm: false
      )
    end

    def listing_anchor(lead, kind, listing_id, anchor_kind)
      if kind == "project"
        project = @projects[listing_id]
        return if project.nil?

        point = Geo.own_pin(
          lat: project.lat, lng: project.lng,
          locality_lat: project.locality&.lat, locality_lng: project.locality&.lng,
          approximate: project.pin_approximate
        )
        return if point.nil?

        Anchor.new(
          lat: point[:lat], lng: point[:lng], kind: anchor_kind, name: project.name,
          listing_kind: "project", listing_id: project.id, other_firm: false
        )
      else
        property = @properties[listing_id]
        return if property.nil?

        point = Geo.own_pin(
          lat: property.lat, lng: property.lng,
          locality_lat: property.locality&.lat, locality_lng: property.locality&.lng,
          approximate: property.pin_approximate
        )
        return if point.nil?

        own = property.firm_id == lead.firm_id
        Anchor.new(
          lat: point[:lat], lng: point[:lng], kind: anchor_kind,
          name: own ? property.title : PropertyCard.for(property)[:title],
          listing_kind: "property", listing_id: property.id, other_firm: !own
        )
      end
    end

    def coord_key(lat, lng)
      [ format("%.7f", lat.to_f), format("%.7f", lng.to_f) ]
    end
  end
end
