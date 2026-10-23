# frozen_string_literal: true

module Inventory
  # Optional facts that differ by configuration. Unknown keys are dropped.
  # A value that is present but not the type or range below is an error.
  class DetailSpecs
    Field = Struct.new(:key, :label, :type, :options, :min, :max, :unit, :required, keyword_init: true)

    def self.field(key, label, type, options: nil, min: nil, max: nil, unit: nil, required: false)
      Field.new(key:, label:, type:, options:, min:, max:, unit:, required:)
    end

    FACING = %w[N NE E SE S SW W NW].freeze
    FURNISHING = %w[unfurnished semi fully].freeze
    FLOOR_LEVEL = %w[basement ground first upper].freeze
    LOCATED_IN = %w[high_street mall market_complex residential_complex standalone].freeze
    INDUSTRIAL_ZONE = %w[midc other_notified none].freeze
    APPROVAL = %w[na_approved_layout na_only not_na].freeze
    WATER_SOURCE = %w[borewell well canal_river none].freeze
    TENANT_TYPES = %w[bank retail_brand fb clinic office_tenant other].freeze

    HOME = [
      field("furnishing", "Furnishing", :select, options: FURNISHING),
      field("covered_parking", "Covered parking", :integer, min: 0, max: 20),
      field("facing", "Facing", :select, options: FACING)
    ].freeze
    PENTHOUSE = (HOME + [ field("private_terrace", "Private terrace", :boolean) ]).freeze
    HOUSE = (HOME + [ field("land_area_sqft", "Land area", :integer, min: 1, unit: "sq ft") ]).freeze
    OFFICE = [
      field("office_furnishing", "Office furnishing", :select,
        options: %w[bare_shell warm_shell semi fully plug_and_play]),
      field("workstations", "Workstations", :integer, min: 0, max: 5_000),
      field("cabins", "Cabins", :integer, min: 0, max: 500),
      field("washrooms", "Washrooms", :select, options: %w[private shared none]),
      field("pantry", "Pantry", :select, options: %w[none dry wet]),
      field("covered_parking", "Covered parking", :integer, min: 0, max: 20)
    ].freeze
    SHOP = [
      field("floor_level", "Floor level", :select, options: FLOOR_LEVEL),
      field("frontage_ft", "Frontage", :integer, min: 1, max: 500, unit: "feet"),
      field("main_road", "Main road", :boolean),
      field("located_in", "Located in", :select, options: LOCATED_IN),
      field("washroom", "Washroom", :boolean)
    ].freeze
    SHOWROOM = [
      field("floor_level", "Floor level", :select, options: FLOOR_LEVEL),
      field("frontage_ft", "Frontage", :integer, min: 1, max: 500, unit: "feet"),
      field("clear_height_ft", "Clear height", :decimal, min: 1, max: 100, unit: "feet"),
      field("main_road", "Main road", :boolean),
      field("covered_parking", "Covered parking", :integer, min: 0, max: 20)
    ].freeze
    WAREHOUSE = [
      field("clear_height_ft", "Clear height", :decimal, min: 1, max: 100, unit: "feet"),
      field("loading_docks", "Loading docks", :integer, min: 0, max: 200),
      field("power_kw", "Power", :integer, min: 0, max: 100_000, unit: "kW"),
      field("road_width_ft", "Road width", :integer, min: 1, max: 300, unit: "feet")
    ].freeze
    INDUSTRIAL_SHED = [
      field("clear_height_ft", "Clear height", :decimal, min: 1, max: 100, unit: "feet"),
      field("power_kw", "Power", :integer, min: 0, max: 100_000, unit: "kW"),
      field("industrial_zone", "Industrial zone", :select, options: INDUSTRIAL_ZONE),
      field("crane", "Crane", :boolean)
    ].freeze
    RESIDENTIAL_PLOT = [
      field("length_ft", "Length", :integer, min: 1, max: 100_000, unit: "feet"),
      field("breadth_ft", "Breadth", :integer, min: 1, max: 100_000, unit: "feet"),
      field("road_width_ft", "Road width", :integer, min: 1, max: 300, unit: "feet"),
      field("facing", "Facing", :select, options: FACING),
      field("corner_plot", "Corner plot", :boolean),
      field("boundary_wall", "Boundary wall", :boolean),
      field("approval", "Approval", :select, options: APPROVAL),
      field("gated_layout", "Gated layout", :boolean)
    ].freeze
    COMMERCIAL_PLOT = [
      field("length_ft", "Length", :integer, min: 1, max: 100_000, unit: "feet"),
      field("breadth_ft", "Breadth", :integer, min: 1, max: 100_000, unit: "feet"),
      field("road_width_ft", "Road width", :integer, min: 1, max: 300, unit: "feet"),
      field("facing", "Facing", :select, options: FACING),
      field("corner_plot", "Corner plot", :boolean),
      field("approval", "Approval", :select, options: APPROVAL)
    ].freeze
    INDUSTRIAL_PLOT = [
      field("road_width_ft", "Road width", :integer, min: 1, max: 300, unit: "feet"),
      field("industrial_zone", "Industrial zone", :select, options: INDUSTRIAL_ZONE),
      field("power_available", "Power available", :boolean)
    ].freeze
    AGRICULTURAL = [
      field("road_access", "Road access", :boolean),
      field("road_width_ft", "Road width", :integer, min: 1, max: 300, unit: "feet"),
      field("water_source", "Water source", :select, options: WATER_SOURCE),
      field("clear_title", "Clear 7/12 title", :boolean)
    ].freeze

    BHK_CODES = %w[1_rk 1_bhk 1_5_bhk 2_bhk 2_5_bhk 3_bhk 3_5_bhk 4_bhk 4_5_bhk 5_bhk 5_plus_bhk].freeze
    BY_CODE = BHK_CODES.index_with { HOME }.merge(
      "penthouse" => PENTHOUSE,
      "villa" => HOUSE,
      "row_house" => HOUSE,
      "office" => OFFICE,
      "shop" => SHOP,
      "showroom" => SHOWROOM,
      "warehouse" => WAREHOUSE,
      "industrial_shed" => INDUSTRIAL_SHED,
      "other_commercial" => [],
      "residential_plot" => RESIDENTIAL_PLOT,
      "commercial_plot" => COMMERCIAL_PLOT,
      "industrial_plot" => INDUSTRIAL_PLOT,
      "agricultural_land" => AGRICULTURAL
    ).freeze

    LEASE = [
      field("lease_monthly_rent", "Lease monthly rent", :integer, min: 1, unit: "rupees", required: true),
      field("lock_in_until", "Lock-in until", :date),
      field("tenant_type", "Tenant type", :select, options: TENANT_TYPES)
    ].freeze
    LEASE_KEYS = LEASE.map(&:key).freeze
    OPTION_LABELS = {
      "unfurnished" => "Unfurnished",
      "semi" => "Semi-furnished",
      "fully" => "Fully furnished",
      "bare_shell" => "Bare shell",
      "warm_shell" => "Warm shell",
      "plug_and_play" => "Plug & play",
      "private" => "Private",
      "shared" => "Shared",
      "none" => "None",
      "dry" => "Dry",
      "wet" => "Wet",
      "basement" => "Basement",
      "ground" => "Ground",
      "first" => "First",
      "upper" => "Upper",
      "high_street" => "High street",
      "mall" => "Mall",
      "market_complex" => "Market complex",
      "residential_complex" => "Residential complex",
      "standalone" => "Standalone",
      "midc" => "MIDC",
      "other_notified" => "Other notified zone",
      "na_approved_layout" => "NA + approved layout",
      "na_only" => "NA only",
      "not_na" => "Not NA",
      "borewell" => "Borewell",
      "well" => "Well",
      "canal_river" => "Canal / river",
      "bank" => "Bank",
      "retail_brand" => "Retail brand",
      "fb" => "F&B",
      "clinic" => "Clinic",
      "office_tenant" => "Office tenant",
      "other" => "Other"
    }.freeze

    Result = Struct.new(:values, :errors, keyword_init: true)

    def self.clean(code, raw, pre_leased:)
      incoming = raw.is_a?(Hash) ? raw.stringify_keys : {}
      known = fields_for(code, pre_leased:)
      values = {}
      errors = []

      known.each do |spec|
        next unless incoming.key?(spec.key)
        next if blank?(incoming[spec.key])

        parsed = cast(spec, incoming[spec.key])
        if parsed.nil?
          errors << message_for(spec)
        else
          values[spec.key] = parsed
        end
      end

      LEASE.select(&:required).each do |spec|
        next unless pre_leased
        next if values.key?(spec.key)

        errors << "#{spec.label} is required for a pre-leased unit"
      end

      Result.new(values:, errors:)
    end

    def self.fields_for(code, pre_leased:)
      rows = Array(BY_CODE[code.to_s])
      pre_leased ? rows + LEASE : rows
    end

    # The shape /reference gives the app. A code with no row here is an empty list.
    def self.reference_for(code)
      fields_for(code, pre_leased: false).map { |spec| reference_field(spec) }
    end

    def self.reference_field(spec)
      {
        key: spec.key,
        label: spec.label,
        type: spec.type.to_s,
        options: Array(spec.options).map { |option| { code: option, label: option_label(option) } },
        min: spec.min,
        max: spec.max,
        unit: spec.unit
      }
    end

    def self.option_label(code)
      OPTION_LABELS.fetch(code, code)
    end

    def self.pre_leased_reference
      LEASE.map { |spec| reference_field(spec) }
    end

    def self.tenant_type_rows
      TENANT_TYPES.map { |code| { code:, name: option_label(code) } }
    end

    def self.blank?(value)
      value.nil? || (value.is_a?(String) && value.strip.empty?)
    end
    private_class_method :blank?

    def self.cast(spec, value)
      case spec.type
      when :integer then cast_integer(value, spec.min, spec.max)
      when :decimal then cast_decimal(value, spec.min, spec.max)
      when :boolean then cast_boolean(value)
      when :select then spec.options.include?(value.to_s) ? value.to_s : nil
      when :date then cast_date(value)
      end
    end
    private_class_method :cast

    def self.cast_integer(value, min, max)
      string = value.to_s.strip
      return nil unless string.match?(/\A\d+\z/)

      number = string.to_i
      return nil if min && number < min
      return nil if max && number > max

      number
    end
    private_class_method :cast_integer

    def self.cast_decimal(value, min, max)
      string = value.to_s.strip
      return nil unless string.match?(/\A\d+(\.\d+)?\z/)

      number = BigDecimal(string)
      return nil if min && number < min.to_d
      return nil if max && number > max.to_d

      number.to_s("F").sub(/\.?0+\z/, "")
    end
    private_class_method :cast_decimal

    def self.cast_boolean(value)
      case value
      when true, false then value
      when "true", "1", 1 then true
      when "false", "0", 0 then false
      end
    end
    private_class_method :cast_boolean

    def self.cast_date(value)
      Date.iso8601(value.to_s)
    rescue Date::Error, ArgumentError
      nil
    end
    private_class_method :cast_date

    def self.message_for(spec)
      case spec.type
      when :integer
        spec.unit ? "#{spec.label} must be a whole number of #{spec.unit}" : "#{spec.label} must be a whole number"
      when :decimal
        spec.unit ? "#{spec.label} must be a number of #{spec.unit}" : "#{spec.label} must be a number"
      when :boolean
        "#{spec.label} must be yes or no"
      when :date
        "#{spec.label} must be a date"
      else
        "#{spec.label} isn't a known option"
      end
    end
    private_class_method :message_for
  end
end
