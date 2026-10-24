# frozen_string_literal: true

module Bookings
  # The booking form sends the configuration id the broker picked. When the
  # project is a marketplace or catalog row, that id belongs to the source,
  # and the booking stores the firm's copy. Match the copy's row by typology
  # and label — the two fields CopyCatalogProject keeps identical.
  class ConfigurationMap
    def self.call(typology_id:, source_project_id:, project:)
      return typology_id if typology_id.blank? || project.nil? || source_project_id.blank?
      return typology_id if project.id.to_s == source_project_id.to_s

      source = ProjectTypology.find_by(id: typology_id)
      return typology_id if source.nil? || source.project_id.to_s != source_project_id.to_s

      project.project_typologies
        .where(typology_id: source.typology_id)
        .where("lower(COALESCE(label, '')) = ?", source.label.to_s.downcase)
        .pick(:id)
    end
  end
end
