# frozen_string_literal: true

module Inventory
  # One-shot production adoption. Idempotent. DRY_RUN=1 prints the same
  # summary and writes nothing.
  class CategoriesBackfill
    def self.call(dry_run: ENV["DRY_RUN"] == "1", output: $stdout)
      new(dry_run:, output:).call
    end

    def initialize(dry_run:, output:)
      @dry_run = dry_run
      @output = output
      @merged = []
      @flagged = []
      @recategorised_codes = []
      @trimmed_codes = []
      @unresolved_codes = []
      @tracked_lead_ids = []
    end

    def call
      Current.set(firm_scope_bypassed: true) do
        Typology.transaction do
          confirm_canonical
          merge_the_rest
          fill_areas
          recategorise_leads
          print_summary
          raise ActiveRecord::Rollback if @dry_run
        end
      end
    end

    private

    def confirm_canonical
      @canonicals = Typology::CANONICAL.map { |row|
        Typology.upsert_canonical!(row, active_on_create: row[:category] == "residential")
      }
    end

    def merge_the_rest
      Typology.where(merged_into_id: nil).where.not(id: @canonicals.map(&:id)).find_each do |typology|
        target = resolve(typology)
        if target.nil? || target.id == typology.id
          typology.update!(needs_review: true) unless typology.needs_review?
          @flagged << typology.name
          next
        end

        source_category = typology.category
        typology.merge_into!(target)
        typology.adopted_leads.each { |lead, result| track_lead(lead, result) }
        @merged << {
          source: typology.name, from: source_category,
          target: target.name, to: target.category, aliased: typology.alias_written?
        }
      end
    end

    # The production row coded "commercial" is Office, and its name is generic
    # so it does not become an alias. Everything else uses resolver steps 3–8.
    def resolve(typology)
      if typology.code == "commercial" || Realtoriq::NameKey.call(typology.name) == "commercial"
        return Typology.find_by(code: "office", merged_into_id: nil)
      end

      Realtoriq::UnitResolver.for_backfill(typology.name)
    end

    def fill_areas
      Property.unscoped.where(area_value: nil).where.not(carpet_area_sqft: nil).find_each do |property|
        property.update_columns(area_value: property.carpet_area_sqft, area_unit: "sqft", updated_at: Time.current)
      end
      ProjectTypology.where(area_value: nil).where.not(starting_carpet_sqft: nil).find_each do |row|
        row.update_columns(area_value: row.starting_carpet_sqft, area_unit: "sqft", updated_at: Time.current)
      end

      rented = Property.unscoped.joins(:typology).where(listing_for: "rent", typologies: { category: "land" })
      @output.puts(rented.any? ? "Land listings for rent: #{rented.pluck(:id).join(', ')}" : "Land listings for rent: none")
    end

    def recategorise_leads
      Lead.unscoped.find_each do |lead|
        track_lead(lead, lead.adopt_category_from_configurations!)
      end
    end

    def track_lead(lead, result)
      return if result == :unchanged || result.nil? || @tracked_lead_ids.include?(lead.id)

      @tracked_lead_ids << lead.id
      case result
      when :recategorised then @recategorised_codes << lead.code
      when :trimmed then @trimmed_codes << lead.code
      when :unresolved then @unresolved_codes << lead.code
      end
    end

    def print_summary
      prefix = @dry_run ? "[dry run] " : ""
      @output.puts "#{prefix}Confirmed #{@canonicals.size} configurations"
      @output.puts "#{prefix}Merged #{@merged.size}"
      @merged.each do |row|
        alias_note = row[:aliased] ? "" : ", no alias"
        @output.puts "#{row[:source]} -> #{row[:target]} (#{row[:from]} -> #{row[:to]}#{alias_note})"
      end
      if @flagged.any?
        @flagged.each { |name| @output.puts "Flagged #{name}" }
      else
        @output.puts "#{prefix}Flagged 0"
      end
      @recategorised_codes.each { |code| @output.puts "Re-categorised #{code}" }
      @trimmed_codes.each { |code| @output.puts "Trimmed #{code}" }
      @unresolved_codes.each { |code| @output.puts "#{code} needs manual review" }
      @output.puts "#{prefix}Leads re-categorised #{@recategorised_codes.size}, trimmed #{@trimmed_codes.size}"
      pending = Typology.where(code: commercial_and_land_codes, active: false, merged_into_id: nil).count
      active = Typology.where(code: commercial_and_land_codes, active: true, merged_into_id: nil).count
      @output.puts "#{prefix}Commercial and land active #{active}, pending activation #{pending}"
    end

    def commercial_and_land_codes
      Typology::CANONICAL.reject { |row| row[:category] == "residential" }.map { |row| row[:code] }
    end
  end
end
