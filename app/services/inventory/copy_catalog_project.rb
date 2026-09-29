# frozen_string_literal: true

module Inventory
  # A booking hangs off a My Projects row. A lead does not: it links the
  # marketplace row itself. This copy is made when the booking is saved.
  # LaunchIQ can withdraw the listing; the booking keeps the firm row.
  # Copies only the fields a booking needs — no photos, brochure, promo or
  # brokerage.
  class CopyCatalogProject
    Result = Struct.new(:ok?, :project, :error_code, :error_message, :details, keyword_init: true)

    def initialize(catalog:, use_existing: false, new_name: nil)
      @catalog = catalog
      @use_existing = use_existing
      @new_name = new_name.to_s.strip.presence
    end

    def call
      return Result.new(ok?: true, project: catalog) if catalog.from_own?
      return copy_marketplace if catalog.marketplace?

      copy_firm_catalog
    end

    private

    attr_reader :catalog, :use_existing, :new_name

    # A global marketplace row is never attached to a same-named project the
    # firm added itself. The firm's copy is the row with this project code.
    # Two requests at once both miss that row, and the unique index keeps one.
    def copy_marketplace
      existing = own_by_code
      return Result.new(ok?: true, project: existing) if existing

      # Savepoint so a clash with a copy another request just inserted does not
      # abort the enquiry transaction this runs inside.
      Project.transaction(requires_new: true) { copy(name: available_name) }
    rescue ActiveRecord::RecordNotUnique
      existing = own_by_code
      return Result.new(ok?: true, project: existing) if existing

      raise
    end

    def own_by_code
      return if catalog.external_ref.blank?

      Project.from_own.find_by(external_ref: catalog.external_ref)
    end

    def available_name
      plain = catalog.name.to_s.strip
      return plain unless name_taken?(plain)

      builder_name = catalog.builder&.name.to_s.strip
      labelled = builder_name.present? ? "#{plain} (#{builder_name})" : "#{plain} 2"
      return labelled unless name_taken?(labelled)

      suffix = 2
      suffix += 1 while name_taken?("#{labelled} #{suffix}")
      "#{labelled} #{suffix}"
    end

    def name_taken?(name)
      Project.from_own.where("LOWER(name) = ?", name.downcase).exists?
    end

    # A catalog row this firm already owns (not a global marketplace listing)
    # still asks the caller what to do when the name is taken.
    def copy_firm_catalog
      clash = Project.from_own.where("LOWER(name) = ?", catalog.name.to_s.downcase).first
      if clash
        return reuse_firm_catalog(clash) if use_existing
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

    def reuse_firm_catalog(existing)
      if existing.external_ref.blank? && catalog.external_ref.present?
        existing.update!(external_ref: catalog.external_ref)
      end

      Result.new(ok?: true, project: existing)
    end

    def copy(name:)
      firm = catalog.firm || Current.firm
      if firm.nil?
        return Result.new(
          ok?: false,
          error_code: "firm_required",
          error_message: "A catalog project can only be copied inside a firm."
        )
      end

      project = Project.new(
        firm:,
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
