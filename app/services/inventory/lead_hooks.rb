# frozen_string_literal: true

module Inventory
  # Preferred localities, their 6 km neighbors, and tagged project or property
  # pins for one lead. Derived on read. A withdrawn project mapping is not a
  # pin. Nearby stays dark until NearbyMatching has a row.
  class LeadHooks
    attr_reader :preferred_ids, :neighbor_distance, :pins, :anchors, :centers,
      :preferred_localities, :neighbor_localities, :visited_project_ids, :visited_property_ids

    def self.for(lead, index: nil)
      new(lead, index:).tap(&:load)
    end

    def initialize(lead, index: nil)
      @lead = lead
      @index = index
      @preferred_ids = []
      @neighbor_distance = {}
      @pins = []
      @anchors = []
      @visited_project_ids = []
      @visited_property_ids = []
      @centers = []
      @preferred_localities = []
      @neighbor_localities = []
    end

    def load
      @preferred_localities = lead.localities.to_a
      @preferred_ids = preferred_localities.map(&:id)
      @centers = preferred_localities.filter_map { |locality| center_point(locality) }
      return self unless nearby_enabled?

      if index
        index.fill(self, lead)
      elsif anchor_mode?
        load_neighbors
        load_anchors
      else
        load_neighbors
        load_pins
      end
      self
    end

    def ranking?
      return false unless nearby_enabled?

      circles = anchor_mode? ? anchors.any? : pins.any?
      centers.any? || neighbor_distance.any? || circles
    end

    def anchor_mode?
      index ? index.anchors : own_anchor_mode?
    end

    def anchor_radius_m
      index ? index.radius_m : own_anchor_radius
    end

    def preferred?(locality_id)
      preferred_ids.include?(locality_id)
    end

    def search_locality_ids
      return preferred_ids unless nearby_enabled?

      preferred_ids + neighbor_distance.keys
    end

    # Filled by HookIndex for a batch. A single lead loads its own rows.
    def install_neighbors(distance, localities)
      @neighbor_distance = distance
      @neighbor_localities = localities
    end

    def install_pins(pin_list)
      pin_list.each { |pin| pins << pin }
    end

    def install_anchors(list, visited_projects: [], visited_properties: [])
      @anchors = Array(list)
      @visited_project_ids = Array(visited_projects)
      @visited_property_ids = Array(visited_properties)
    end

    private

    attr_reader :lead, :index

    # Memoized on this object only. A thread or class cache would keep a stale
    # false after the enable rake, or leak across requests.
    def nearby_enabled?
      return index.nearby if index
      return @nearby_enabled unless @nearby_enabled.nil?

      @nearby_enabled = NearbyMatching.enabled? || own_anchor_mode?
    end

    def read_own_anchor_switch
      return if defined?(@own_anchor_radius)

      @own_anchor_radius = AnchorMatching.pick(:radius_m)
    end

    def own_anchor_mode?
      read_own_anchor_switch
      !@own_anchor_radius.nil?
    end

    def own_anchor_radius
      read_own_anchor_switch
      @own_anchor_radius
    end

    def load_anchors
      bundle = LeadAnchors.for([ lead ])
      install_anchors(
        bundle[lead.id],
        visited_projects: bundle.visited_project_ids[lead.id],
        visited_properties: bundle.visited_property_ids[lead.id]
      )
    end

    def load_neighbors
      return if preferred_ids.empty?

      rows = LocalityNeighbor.where(locality_id: preferred_ids).pluck(:neighbor_locality_id, :distance_m)
      rows.each do |locality_id, metres|
        next if preferred?(locality_id)

        neighbor_distance[locality_id] = [ neighbor_distance[locality_id], metres ].compact.min
      end
      @neighbor_localities = Locality.where(id: neighbor_distance.keys).map do |locality|
        { id: locality.id, name: locality.name, distance_m: neighbor_distance[locality.id] }
      end
    end

    # Unscoped on purpose. lead.lead_projects is firm-scoped, so another firm's
    # marketplace lead would look unpinned and drop out of the circle.
    def load_pins
      project_ids = LeadProject.unscoped.where(lead_id: lead.id, withdrawn_at: nil).pluck(:project_id)
      if project_ids.any?
        Project.unscoped.where(id: project_ids).includes(:locality).find_each do |project|
          remember_pin(project.lat, project.lng, project.locality, project.city_id, approximate: project.pin_approximate)
        end
      end

      property_ids = LeadProperty.unscoped.where(lead_id: lead.id).pluck(:property_id)
      return if property_ids.empty?

      properties = Property.unscoped.where(id: property_ids).includes(:locality).to_a
      properties.each do |property|
        remember_pin(
          property.lat, property.lng, property.locality, property.city_id,
          other_firm: property.firm_id != lead.firm_id, approximate: property.pin_approximate
        )
      end
    end

    def remember_pin(lat, lng, locality, city_id, other_firm: false, approximate: false)
      own = Geo.own_pin(lat:, lng:, locality_lat: locality&.lat, locality_lng: locality&.lng, approximate:)
      point = Geo.listing_point(lat:, lng:, locality_lat: locality&.lat, locality_lng: locality&.lng, approximate:)
      return if point.nil? || city_id.blank?

      pins << point.merge(city_id:, own: !own.nil?, other_firm:)
    end

    def center_point(locality)
      point = Geo.listing_point(lat: nil, lng: nil, locality_lat: locality.lat, locality_lng: locality.lng)
      point&.merge(locality_id: locality.id)
    end
  end
end
