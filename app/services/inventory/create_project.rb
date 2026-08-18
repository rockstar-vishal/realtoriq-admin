# frozen_string_literal: true

module Inventory
  # A project, its typologies and its brochure in one transaction — a project
  # saved without the configurations the broker chose is worse than no project,
  # because the price band it shows would be empty.
  class CreateProject
    Result = Struct.new(:ok?, :project, :errors, keyword_init: true)

    def initialize(firm:, attributes:, typologies: [], brochure_signed_id: nil)
      @firm = firm
      @attributes = attributes
      @typologies = Array(typologies)
      @brochure_signed_id = brochure_signed_id
    end

    def call
      project = Project.new(attributes)
      project.firm = firm
      # Everything created through this API is the firm's own. Catalog rows will
      # arrive from the turbo-rails8 feed carrying an external_ref.
      project.source = :own

      Project.transaction do
        project.save!
        add_typologies(project)
        attach_brochure(project)
      end

      Result.new(ok?: true, project: project.reload)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok?: false, project: e.record, errors: e.record.errors)
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      project.errors.add(:brochure, "isn't a valid upload")
      Result.new(ok?: false, project:, errors: project.errors)
    end

    private

    attr_reader :firm, :attributes, :typologies, :brochure_signed_id

    def add_typologies(project)
      typologies.each do |row|
        attrs = row.respond_to?(:permit) ? row.permit(:typology_id, :starting_price, :starting_carpet_sqft) : row
        project.project_typologies.create!(attrs)
      end
    end

    def attach_brochure(project)
      return if brochure_signed_id.blank?

      project.brochure.attach(brochure_signed_id)
    end
  end
end
