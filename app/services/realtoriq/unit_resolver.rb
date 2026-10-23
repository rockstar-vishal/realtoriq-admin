# frozen_string_literal: true

module Realtoriq
  # Turns a LaunchIQ unit into one canonical configuration.
  #
  # `for_backfill` is steps 3–8 only: the configuration name, no unit label,
  # no LaunchIQ category, and no fallback. The full call is steps 1–11.
  class UnitResolver
    # "1RK" has no word boundary between the digit and the letters, so the
    # boundary sits after rk/bhk. "2 & 3 Bed" does not match.
    BHK = /(\d+(?:\.\d)?)\s*-?\s*(bhk|rk)\b/i

    Result = Struct.new(:typology, :needs_review, :bhk_conflict, :review, keyword_init: true)
    Bhk = Struct.new(:kind, :number, keyword_init: true)

    def self.call(typology_name:, typology_category: nil, label: nil)
      new(typology_name:, typology_category:, label:).resolve
    end

    def self.for_backfill(name)
      new(typology_name: name).backfill_typology
    end

    def initialize(typology_name:, typology_category: nil, label: nil)
      @typology_name = typology_name.to_s.strip
      @label = label.to_s.strip
      @typology_category = typology_category.to_s.strip.presence
      # "Commercial" and "Others" name a category, not a configuration.
      @configuration_name = Typology.generic_name?(@typology_name) ? "" : @typology_name
    end

    def resolve
      if (found = alias_for(@label))
        return finish(found, needs_review: false, bhk_conflict: false)
      end

      label_bhk = bhk_identity(@label)
      if (typology = typology_for_bhk(label_bhk))
        conflict = bhk_differs?(@configuration_name, label_bhk)
        return fallback(bhk_conflict: conflict) if category_disagrees?(typology)

        return finish(
          typology, needs_review: conflict, bhk_conflict: conflict,
          review: (:bhk_conflict if conflict)
        )
      end

      if (found = alias_for(@configuration_name))
        return finish(found, needs_review: false, bhk_conflict: false)
      end

      classified = classified_typology
      if classified
        return fallback(bhk_conflict: false) if category_disagrees?(classified)

        return finish(classified, needs_review: false, bhk_conflict: false)
      end

      bare = bare_plot_typology
      return bare if bare

      fallback(bhk_conflict: false)
    end

    # Steps 3–8. A generic name, a bare plot, and anything still unknown stay
    # unresolved so the backfill can flag them instead of inventing a row.
    def backfill_typology
      return if @typology_name.blank? || Typology.generic_name?(@typology_name)

      alias_for(@typology_name) ||
        typology_for_bhk(bhk_identity(@typology_name)) ||
        exact_typology(@typology_name) ||
        residential_word(@typology_name) ||
        commercial_word(@typology_name) ||
        plot_qualifier(@typology_name)
    end

    private

    # Canonical rows only, including ones still inactive. A variant named
    # "Retail Shop" must not count as an exact match for itself.
    def pool
      codes = Typology::CANONICAL.map { |row| row[:code] }
      @pool ||= Typology.where(merged_into_id: nil, code: codes).to_a
    end

    def by_code(code)
      pool.find { |typology| typology.code == code }
    end

    def finish(typology, needs_review:, bhk_conflict:, review: nil)
      Result.new(
        typology:, needs_review:, bhk_conflict:,
        review: needs_review ? review : nil
      )
    end

    def alias_for(text)
      return if text.blank?

      typology = ConfigurationAlias.find_by(key: NameKey.call(text))&.typology
      return if typology.nil? || typology.merged_into_id.present?

      typology
    end

    def bhk_identity(text)
      match = text.to_s.match(BHK)
      return if match.nil?

      Bhk.new(kind: match[2].downcase, number: BigDecimal(match[1]))
    end

    def bhk_differs?(text, identity)
      other = bhk_identity(text)
      return false if other.nil?

      other.kind != identity.kind || other.number != identity.number
    end

    def typology_for_bhk(identity)
      return if identity.nil?
      return by_code("1_rk") if identity.kind == "rk"

      code = if identity.number > 5
        "5_plus_bhk"
      elsif identity.number.frac.zero?
        "#{identity.number.to_i}_bhk"
      else
        whole, fraction = identity.number.to_s("F").split(".")
        "#{whole}_#{fraction}_bhk"
      end
      by_code(code) || by_code("5_plus_bhk")
    end

    # Step 4, then 5–8. Within each step the configuration name is tried
    # before the unit label.
    def classified_typology
      typology_for_bhk(bhk_identity(@configuration_name)) ||
        exact_typology(@configuration_name) || exact_typology(@label) ||
        residential_word(@configuration_name) || residential_word(@label) ||
        commercial_word(@configuration_name) || commercial_word(@label) ||
        plot_qualifier(@configuration_name) || plot_qualifier(@label)
    end

    def exact_typology(text)
      return if text.blank?

      key = NameKey.call(text)
      return if key.blank?

      pool.find { |typology| NameKey.call(typology.name) == key }
    end

    def residential_word(text)
      key = NameKey.call(text)
      return if key.blank?
      return by_code("villa") if key.include?("villa") || key.include?("bungalow")
      return by_code("penthouse") if key.include?("penthouse")
      return by_code("row_house") if key.include?("rowhouse")
      return by_code("1_rk") if key.include?("studio")

      nil
    end

    def commercial_word(text)
      key = NameKey.call(text)
      return if key.blank?
      return by_code("showroom") if key.include?("showroom")
      return by_code("shop") if key.include?("shop") || key.include?("retail")
      return by_code("office") if key.include?("office")
      return by_code("warehouse") if key.include?("warehouse") || key.include?("godown")
      return by_code("industrial_shed") if key.include?("shed") || key.include?("factory")

      nil
    end

    # A bare "plot" is step 9. "NA" is a word, so "Kanakia" does not count.
    def plot_qualifier(text)
      return if text.blank?

      key = NameKey.call(text)
      return unless key.include?("plot") || key.include?("land")
      return by_code("agricultural_land") if key.include?("agri") || key.include?("farm")
      return by_code("industrial_plot") if key.include?("industrial") || key.include?("midc")
      return by_code("commercial_plot") if key.include?("commercial")
      return by_code("residential_plot") if key.include?("residential") || text.match?(/\bna\b/i)

      nil
    end

    def bare_plot_typology
      return unless bare_plot?(@typology_name) || bare_plot?(@label)

      code, flagged = case @typology_category
      when "commercial" then [ "commercial_plot", false ]
      when "residential" then [ "residential_plot", false ]
      else [ "residential_plot", true ]
      end
      typology = by_code(code)
      return if typology.nil?

      finish(
        typology, needs_review: flagged, bhk_conflict: false,
        review: (:bare_plot if flagged)
      )
    end

    def bare_plot?(text)
      return false if text.blank?

      key = NameKey.call(text)
      key.include?("plot") || key.include?("land")
    end

    # An alias is an ops decision and is not overridden. Steps 2–8 are.
    def category_disagrees?(typology)
      @typology_category.present? && typology.category != @typology_category
    end

    def fallback(bhk_conflict:)
      typology = case @typology_category
      when "land" then by_code("residential_plot")
      when "residential" then residential_fallback(fallback_name)
      else by_code("other_commercial")
      end
      finish(typology, needs_review: true, bhk_conflict:, review: :fallback)
    end

    def fallback_name
      [ @configuration_name, @label ].find(&:present?)
    end

    # The next push of the same unknown home must reuse the row, not insert
    # a second one. The name is unique.
    def residential_fallback(name)
      return if name.blank?

      existing = Typology.where(merged_into_id: nil).where("lower(name) = ?", name.downcase).first
      if existing&.residential? && existing.category_confirmed_at.nil?
        existing.update!(needs_review: true) unless existing.needs_review?
        return existing
      end
      return if existing

      Typology.create!(
        name:, category: "residential", active: false, needs_review: true
      )
    end
  end
end
