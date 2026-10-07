# frozen_string_literal: true

module Inventory
  # A project, its typologies and its brochure in one transaction — a project
  # saved without the configurations the broker chose is worse than no project,
  # because the price band it shows would be empty.
  class CreateProject
    Result = Struct.new(:ok?, :project, :errors, :error_code, :error_message, keyword_init: true)

    def initialize(firm:, attributes:, typologies: [], brochure_signed_id: nil, brokerage_ladder_signed_id: nil)
      @firm = firm
      @attributes = attributes
      @typologies = Array(typologies)
      @brochure_signed_id = brochure_signed_id
      @brokerage_ladder_signed_id = brokerage_ladder_signed_id
    end

    def call
      project = Project.new(attributes)
      project.firm = firm
      # Everything created through this API is the firm's own. Catalog rows will
      # arrive from the turbo-rails8 feed carrying an external_ref.
      project.source = :own

      brochure = take_upload(brochure_signed_id, "project_brochure")
      return brochure if brochure.is_a?(Result)

      ladder = take_upload(brokerage_ladder_signed_id, "project_brokerage_ladder")
      return ladder if ladder.is_a?(Result)

      Project.transaction do
        project.save!
        add_typologies(project)
        ProjectMatchFields.apply(project)
        raise ActiveRecord::RecordInvalid, project if project.errors.any?

        project.brochure.attach(brochure) if brochure
        project.brokerage_ladder.attach(ladder) if ladder
      end

      Result.new(ok?: true, project: project.reload)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok?: false, project: e.record, errors: e.record.errors)
    end

    private

    attr_reader :firm, :attributes, :typologies, :brochure_signed_id, :brokerage_ladder_signed_id

    # nil when there is no file. A Result when the ticket is refused.
    def take_upload(signed_id, purpose)
      return if signed_id.blank?

      accepted = Uploads::AcceptSignedId.new(signed_id:, firm:, purpose:).call
      return accepted.blob if accepted.ok?

      Result.new(ok?: false, error_code: accepted.error_code, error_message: accepted.error_message)
    end

    def add_typologies(project)
      typologies.each do |row|
        attrs = row.respond_to?(:permit) ? row.permit(:typology_id, :starting_price, :starting_carpet_sqft) : row
        project.project_typologies.create!(attrs)
      end
    end
  end
end
