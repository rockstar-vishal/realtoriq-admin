# frozen_string_literal: true

module Inventory
  # A shared listing's building belongs to another firm. The association's
  # firm scope would hide it, so matching attaches the row explicitly.
  module Buildings
    module_function

    def attach(properties)
      records = Array(properties).compact
      return if records.empty?

      buildings = Building.unscoped.where(id: records.map(&:building_id)).includes(:locality, :city).index_by(&:id)
      records.each do |property|
        building = buildings[property.building_id]
        next if building.nil?

        association = property.association(:building)
        association.target = building
        association.loaded!
      end
    end
  end
end
