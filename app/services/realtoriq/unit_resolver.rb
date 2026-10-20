# frozen_string_literal: true

module Realtoriq
  # Steps 3–8 of the configuration resolver. The backfill calls this with the
  # configuration name only. PR 2 adds the LaunchIQ category, the unit label,
  # and the remaining steps around these.
  class UnitResolver
    BHK = /(\d+(?:\.\d)?)\s*-?\s*(bhk|rk)\b/i

    def self.for_backfill(name)
      new(name).call
    end

    def initialize(name)
      @name = name.to_s
      @key = NameKey.call(@name)
    end

    def call
      return if Typology.generic_name?(@name)

      step_alias || step_bhk || step_exact || step_residential_words ||
        step_commercial_words || step_plot_qualifier
    end

    private

    # Canonical rows only. A variant named "Retail Shop" must not count as an
    # exact match for itself.
    def pool
      codes = Typology::CANONICAL.map { |row| row[:code] }
      @pool ||= Typology.where(merged_into_id: nil, code: codes).to_a
    end

    def by_code(code)
      pool.find { |typology| typology.code == code }
    end

    def step_alias
      found = ConfigurationAlias.find_by(key: @key)
      typology = found&.typology
      return if typology.nil? || typology.merged_into_id.present?

      typology
    end

    def step_bhk
      match = @name.match(BHK)
      return if match.nil?

      by_code(bhk_code(match[1], match[2].downcase))
    end

    def bhk_code(number, kind)
      return "1_rk" if kind == "rk"

      value = BigDecimal(number)
      return "5_plus_bhk" if value > 5

      code = if value.frac.zero?
        "#{value.to_i}_bhk"
      else
        whole, fraction = value.to_s("F").split(".")
        "#{whole}_#{fraction}_bhk"
      end
      by_code(code) ? code : "5_plus_bhk"
    end

    def step_exact
      pool.find { |typology| NameKey.call(typology.name) == @key }
    end

    def step_residential_words
      return by_code("row_house") if @key.include?("rowhouse")
      return by_code("villa") if @key.include?("villa")
      return by_code("penthouse") if @key.include?("penthouse")

      nil
    end

    def step_commercial_words
      return by_code("showroom") if @key.include?("showroom")
      return by_code("shop") if @key.include?("shop") || @key.include?("retail")
      return by_code("warehouse") if @key.include?("warehouse") || @key.include?("godown")
      return by_code("industrial_shed") if @key.include?("industrialshed") || @key.include?("shed")
      return by_code("office") if @key.include?("office")

      nil
    end

    # Bare "plot" is step 9 and stays unresolved here.
    def step_plot_qualifier
      return unless @key.include?("plot") || @key.include?("land")
      return by_code("agricultural_land") if @key.include?("agri") || @key.include?("farm")
      return by_code("industrial_plot") if @key.include?("industrial")
      return by_code("commercial_plot") if @key.include?("commercial")
      return by_code("residential_plot") if @key.include?("residential") || @key.include?("bungalow") || @key.include?("villa")

      nil
    end
  end
end
