# frozen_string_literal: true

module Inventory
  # Preferred localities, their 6 km neighbors, and tagged project or property
  # pins for one lead. Derived on read. A withdrawn project mapping is not a
  # pin. Nearby stays dark until NearbyMatching has a row.
  class LeadHooks
    attr_reader :preferred_ids, :neighbor_distance, :pins, :centers, :preferred_localities, :neighbor_localities

    def self.for(lead, index: nil)
      new(lead, index:).tap(&:load)
    end

    def initialize(lead, index: nil)
      @lead = lead
      @index = index
      @preferred_ids = []
      @neighbor_distance = {}
      @pins = []
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
      else
        load_neighbors
        load_pins
      end
      self
    end

    def ranking?
      nearby_enabled? && (centers.any? || neighbor_distance.any? || pins.any?)
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

    private

    attr_reader :lead, :index

    # Memoized on this object only. A thread or class cache would keep a stale
    # false after the enable rake, or leak across requests.
    def nearby_enabled?
      return @nearby_enabled unless @nearby_enabled.nil?

      @nearby_enabled = index ? index.nearby : NearbyMatching.enabled?
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
          remember_pin(project.lat, project.lng, project.locality, project.city_id)
        end
      end

      property_ids = LeadProperty.unscoped.where(lead_id: lead.id).pluck(:property_id)
      return if property_ids.empty?

      properties = Property.unscoped.where(id: property_ids).to_a
      Buildings.attach(properties)
      properties.each do |property|
        building = property.building
        next if building.nil?

        remember_pin(building.lat, building.lng, building.locality, building.city_id)
      end
    end

    def remember_pin(lat, lng, locality, city_id)
      point = Geo.listing_point(lat:, lng:, locality_lat: locality&.lat, locality_lng: locality&.lng)
      return if point.nil? || city_id.blank?

      pins << point.merge(city_id:)
    end

    def center_point(locality)
      point = Geo.listing_point(lat: nil, lng: nil, locality_lat: locality.lat, locality_lng: locality.lng)
      point&.merge(locality_id: locality.id)
    end
  end
end
