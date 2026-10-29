# frozen_string_literal: true

module Marketing
  # A booking copy points at the catalog row by the LaunchIQ code. Creatives
  # and registrations live on that row.
  module CatalogProject
    def self.for(project)
      return project if project&.marketplace?
      return if project.nil? || project.external_ref.blank?

      Project.marketplace.find_by(external_ref: project.external_ref)
    end
  end
end
