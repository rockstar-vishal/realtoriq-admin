# frozen_string_literal: true

module Inventory
  # Pins and neighbor rows for one batch of leads. Thrown away with the caller.
  # Mappings are loaded without the firm scope: a marketplace lead belongs to
  # another firm, and that association would come back empty. Only coordinates
  # are kept. Project names and addresses are not.
  class HookIndex
    attr_reader :nearby

    def self.for(leads, nearby:)
      new(leads, nearby:)
    end

    def initialize(leads, nearby:)
      @leads = Array(leads)
      @nearby = nearby
      @pins = {}
      @by_locality = {}
      @names = {}
      return unless nearby && @leads.any?

      load_neighbors
      load_pins
    end

    def fill(hooks, lead)
      hooks.install_neighbors(*neighbors_for(hooks.preferred_ids))
      hooks.install_pins(@pins[lead.id] || [])
    end

    private

    def load_neighbors
      preferred_ids = @leads.flat_map { |lead| lead.localities.map(&:id) }.uniq
      return if preferred_ids.empty?

      rows = LocalityNeighbor.where(locality_id: preferred_ids)
        .pluck(:locality_id, :neighbor_locality_id, :distance_m)
      neighbor_ids = []
      rows.each do |locality_id, neighbor_id, metres|
        (@by_locality[locality_id] ||= []) << [ neighbor_id, metres ]
        neighbor_ids << neighbor_id
      end
      @names = Locality.where(id: neighbor_ids.uniq).pluck(:id, :name).to_h
    end

    def load_pins
      ids = @leads.map(&:id)
      project_map = grouped(LeadProject.unscoped.where(lead_id: ids, withdrawn_at: nil), :project_id)
      property_map = grouped(LeadProperty.unscoped.where(lead_id: ids), :property_id)
      projects = project_points(project_map.values.flatten.uniq)
      properties = property_points(property_map.values.flatten.uniq)

      ids.each do |lead_id|
        points = Array(project_map[lead_id]).filter_map { |project_id| projects[project_id] }
        points.concat(Array(property_map[lead_id]).filter_map { |property_id| properties[property_id] })
        @pins[lead_id] = points
      end
    end

    def grouped(scope, column)
      scope.pluck(:lead_id, column).each_with_object({}) do |(lead_id, record_id), map|
        (map[lead_id] ||= []) << record_id
      end
    end

    def project_points(ids)
      return {} if ids.empty?

      points = {}
      Project.unscoped.where(id: ids).includes(:locality).each do |project|
        points[project.id] = pin_point(project.lat, project.lng, project.locality, project.city_id)
      end
      points
    end

    def property_points(ids)
      return {} if ids.empty?

      rows = Property.unscoped.where(id: ids).to_a
      Buildings.attach(rows)
      rows.each_with_object({}) do |property, points|
        building = property.building
        next if building.nil?

        points[property.id] = pin_point(building.lat, building.lng, building.locality, building.city_id)
      end
    end

    def pin_point(lat, lng, locality, city_id)
      point = Geo.listing_point(lat:, lng:, locality_lat: locality&.lat, locality_lng: locality&.lng)
      return if point.nil? || city_id.blank?

      point.merge(city_id:)
    end

    def neighbors_for(preferred_ids)
      distance = {}
      preferred_ids.each do |locality_id|
        Array(@by_locality[locality_id]).each do |neighbor_id, metres|
          next if preferred_ids.include?(neighbor_id)

          distance[neighbor_id] = [ distance[neighbor_id], metres ].compact.min
        end
      end
      localities = distance.map { |id, metres| { id:, name: @names[id], distance_m: metres } }
      [ distance, localities ]
    end
  end
end
