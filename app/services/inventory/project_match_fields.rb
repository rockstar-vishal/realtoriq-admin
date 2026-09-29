# frozen_string_literal: true

module Inventory
  # Broker create and update of an own project. A booking copy of a catalog
  # project does not come through here, so a catalog row with no locality can
  # still be booked.
  module ProjectMatchFields
    module_function

    def apply(project)
      project.errors.add(:locality_id, "is required") if project.locality_id.blank?
      return if project.project_typologies.any? { |row| row.starting_price.to_i.positive? }

      project.errors.add(:base, "Add at least one configuration with a price")
    end
  end
end
