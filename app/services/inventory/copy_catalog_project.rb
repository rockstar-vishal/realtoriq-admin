# frozen_string_literal: true

module Inventory
  # Booking must hang off a My Projects row, not a catalog one: LaunchIQ can
  # withdraw a listing, and `belongs_to :project` would then hide the money.
  # Copies only the fields a booking needs to survive — no photos, brochure,
  # promo or brokerage.
  class CopyCatalogProject
    Result = Struct.new(:ok?, :project, :error_code, :error_message, :details, keyword_init: true)

    def initialize(catalog:, use_existing: false, new_name: nil)
      @catalog = catalog
      @use_existing = use_existing
      @new_name = new_name.to_s.strip.presence
    end

    def call
      return Result.new(ok?: true, project: catalog) if catalog.from_own?

      clash = own_name_clash(catalog.name)
      if clash
        return reuse(clash) if use_existing
        return copy(name: new_name) if new_name.present?

        return Result.new(
          ok?: false,
          error_code: "project_name_clash",
          error_message: "My Projects already has a project with this name.",
          details: { existing_project_id: clash.id, name: clash.name }
        )
      end

      copy(name: catalog.name)
    end

    private

    attr_reader :catalog, :use_existing, :new_name

    def own_name_clash(name)
      Project.from_own.where("LOWER(name) = ?", name.to_s.downcase).first
    end

    def reuse(existing)
      if existing.external_ref.blank? && catalog.external_ref.present?
        existing.update!(external_ref: catalog.external_ref)
      end

      Result.new(ok?: true, project: existing)
    end

    def copy(name:)
      project = Project.new(
        firm: catalog.firm,
        source: :own,
        name:,
        builder: catalog.builder,
        city: catalog.city,
        locality: catalog.locality,
        address: catalog.address,
        lat: catalog.lat,
        lng: catalog.lng,
        google_place_id: catalog.google_place_id,
        starting_budget: catalog.starting_budget,
        possession_on: catalog.possession_on,
        possession_label: catalog.possession_label,
        rera_number: catalog.rera_number,
        external_ref: catalog.external_ref
      )
      project.save!
      catalog.project_typologies.each do |row|
        project.project_typologies.create!(
          typology_id: row.typology_id,
          starting_price: row.starting_price,
          starting_carpet_sqft: row.starting_carpet_sqft
        )
      end

      Result.new(ok?: true, project: project.reload)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok?: false, project: e.record, error_code: "invalid",
                 error_message: e.record.errors.full_messages.to_sentence,
                 details: e.record.errors.to_hash)
    end
  end
end
