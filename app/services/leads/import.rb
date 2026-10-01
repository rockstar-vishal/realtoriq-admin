# frozen_string_literal: true

require "csv"

module Leads
  # One CSV, one lead per row. A bad row is reported and does not undo the
  # rows already added. Nothing is written until the file itself is readable
  # and within the row cap.
  class Import
    MAX_ROWS = 200
    MAX_CODES = 20
    EXAMPLE_NAME = "example lead"
    EXAMPLE_MOBILE_DIGITS = "9000000000"
    LAUNCHIQ_CODE = /\APR[0-9A-F]+\z/i
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
    XLSX_MAGIC = "PK\x03\x04".b

    HEADERS = [
      [ :name, "Name" ],
      [ :mobile, "Mobile" ],
      [ :alt_mobile, "Alt mobile" ],
      [ :email, "Email" ],
      [ :transaction_type, "Sale or rent" ],
      [ :property_type, "Property type" ],
      [ :budget, "Budget" ],
      [ :configurations, "Configurations" ],
      [ :location, "Location" ],
      [ :possession, "Possession" ],
      [ :source, "Source" ],
      [ :source_detail, "Source detail" ],
      [ :notes, "Notes" ],
      [ :project_codes, "Project codes" ],
      [ :property_codes, "Property codes" ]
    ].freeze

    HEADER_ALIASES = {
      "phone" => :mobile,
      "alt phone" => :alt_mobile,
      "transaction type" => :transaction_type,
      "configuration" => :configurations,
      "locality" => :location,
      "project code" => :project_codes,
      "property code" => :property_codes
    }.freeze

    Result = Struct.new(:file_error, :created_count, :failed_count, :results, keyword_init: true) do
      def as_json(*)
        { created_count:, failed_count:, results: }
      end
    end

    class RowFailed < StandardError; end
    Rejection = Struct.new(:message)

    def self.template
      CSV.generate do |csv|
        csv << HEADERS.map(&:last)
        csv << [
          "Example lead", "9000000000", nil, nil, "sale", "Under construction",
          "12000000", "2 BHK", "Kharghar, Mumbai", "31/12/2027", "Referral",
          nil, "Higher floor", nil, nil
        ]
      end
    end

    # A shared listing's building belongs to the other firm. The association
    # is firm-scoped, so it reads as missing unless we ask across firms.
    def self.listing_building(property)
      loaded = property.association(:building)
      return loaded.target if loaded.loaded? && loaded.target

      Building.across_firms.includes(:locality, :city).find_by(id: property.building_id)
    end

    def initialize(firm:, actor:, io:)
      @firm = firm
      @actor = actor
      @io = io
    end

    def call
      rows = parse_sheet
      return file_result(rows) if rows.is_a?(String)
      return file_result("The file has no leads to import.") if rows.empty?
      if rows.size > MAX_ROWS
        return file_result("A file can have at most #{MAX_ROWS} leads. Split this one and import it in parts.")
      end

      results = rows.map { |row| import_row(row) }
      Result.new(
        created_count: results.count { |row| row[:status] == "created" },
        failed_count: results.count { |row| row[:status] == "failed" },
        results:
      )
    end

    private

    attr_reader :firm, :actor, :io

    def file_result(message)
      Result.new(file_error: message, created_count: 0, failed_count: 0, results: [])
    end

    def parse_sheet
      raw = io.to_s.dup.force_encoding(Encoding::BINARY)
      return workbook_message if raw.start_with?(XLSX_MAGIC)

      text = raw.force_encoding(Encoding::UTF_8)
      return "This file could not be read. Save it as CSV UTF-8 (comma separated) and upload that." unless text.valid_encoding?

      text = text.sub(/\A\uFEFF/, "")
      return semicolon_message if semicolon_file?(text)
      return "The file is empty." if text.strip.empty?

      table = CSV.parse(text, headers: true)
      return "The file is empty." if table.headers.compact.empty?

      missing = required_headers_missing(table.headers)
      return "The file is missing a #{missing} column." if missing

      rows = []
      table.each.with_index(2) do |csv_row, line|
        fields = extract(csv_row)
        next if blank_fields?(fields) || example_row?(fields)

        rows << { line:, fields:, cells: cells_for(fields) }
      end
      rows
    rescue CSV::MalformedCSVError
      "This file could not be read. Save it as CSV UTF-8 (comma separated) and upload that."
    end

    def workbook_message
      "This is an Excel workbook. Save it as CSV UTF-8 (comma separated) and upload that file."
    end

    def semicolon_message
      "This file uses semicolons. Save it as CSV UTF-8 (comma separated) and upload that."
    end

    def semicolon_file?(text)
      first = text.lines.first.to_s
      first.count(";").positive? && first.count(",").zero?
    end

    def required_headers_missing(headers)
      keys = headers.filter_map { |header| header_key(header) }
      return "Mobile" unless keys.include?(:mobile)
      return "Sale or rent" unless keys.include?(:transaction_type)
      return "Budget" unless keys.include?(:budget)

      nil
    end

    def header_key(header)
      label = header.to_s.sub(/\A\uFEFF/, "").downcase.gsub(/[*]+/, "").gsub(/[_\s]+/, " ").strip
      return if label.empty?

      HEADERS.to_h { |key, name| [ name.downcase, key ] }[label] || HEADER_ALIASES[label]
    end

    def extract(csv_row)
      fields = HEADERS.to_h { |key, _name| [ key, nil ] }
      csv_row.headers.each do |header|
        key = header_key(header)
        fields[key] = csv_row[header] if key
      end
      fields
    end

    def cells_for(fields)
      HEADERS.to_h { |key, name| [ name, fields[key].to_s ] }
    end

    def blank_fields?(fields)
      fields.values.all? { |value| value.to_s.strip.empty? }
    end

    def example_row?(fields)
      fields[:name].to_s.strip.casecmp(EXAMPLE_NAME).zero? &&
        fields[:mobile].to_s.gsub(/\D/, "").sub(/\A0+/, "").then { |digits| digits == EXAMPLE_MOBILE_DIGITS || digits == "91#{EXAMPLE_MOBILE_DIGITS}" }
    end

    def import_row(row)
      prepared = prepare(row[:fields])
      return failure(row, prepared) if prepared.is_a?(String)

      lead = nil
      Lead.transaction do
        result = create_lead(prepared)
        raise RowFailed, failure_message(result, prepared) unless result.ok?

        link(result.lead, prepared)
        lead = result.lead
      end
      {
        row: row[:line], status: "created", name: prepared[:name], mobile: row[:fields][:mobile].to_s.strip,
        lead_id: lead.id, lead_code: lead.code, error: nil
      }
    rescue RowFailed => e
      failure(row, e.message)
    rescue ActiveRecord::RecordInvalid => e
      failure(row, e.record.errors.full_messages.to_sentence)
    end

    def failure(row, message)
      {
        row: row[:line], status: "failed", name: row[:fields][:name].to_s.strip.presence,
        mobile: row[:fields][:mobile].to_s.strip, error: message, cells: row[:cells]
      }
    end

    def prepare(fields)
      mobile = parse_mobile(fields[:mobile], "Mobile", required: true)
      return mobile.message if mobile.is_a?(Rejection)

      alt_mobile = parse_mobile(fields[:alt_mobile], "Alt mobile", required: false)
      return alt_mobile.message if alt_mobile.is_a?(Rejection)

      type = parse_transaction(fields[:transaction_type])
      return type.message if type.is_a?(Rejection)

      budget = parse_budget(fields[:budget])
      return budget.message if budget.is_a?(Rejection)

      property_type = parse_property_type(fields[:property_type], type)
      return property_type.message if property_type.is_a?(Rejection)

      email = parse_email(fields[:email])
      return email.message if email.is_a?(Rejection)

      possession = parse_possession(fields[:possession])
      return possession.message if possession.is_a?(Rejection)

      source = parse_source(fields[:source])
      return source.message if source.is_a?(Rejection)

      projects = resolve_codes(fields[:project_codes], :project)
      return projects.message if projects.is_a?(Rejection)

      properties = resolve_codes(fields[:property_codes], :property)
      return properties.message if properties.is_a?(Rejection)

      compatible = codes_match_transaction(type, projects, properties)
      return compatible.message if compatible.is_a?(Rejection)

      typologies = resolve_typologies(fields[:configurations], projects, properties)
      return typologies.message if typologies.is_a?(Rejection)

      localities = resolve_localities(fields[:location], projects, properties)
      return localities.message if localities.is_a?(Rejection)

      {
        name: fields[:name].to_s.strip.presence,
        mobile:, alt_mobile:, email:, transaction_type: type, property_type:, budget:,
        possession:, source:, source_detail: fields[:source_detail].to_s.strip.presence,
        notes: fields[:notes].to_s.strip.presence, projects:, properties:, typologies:, localities:
      }
    end

    def parse_mobile(raw, label, required:)
      text = raw.to_s.strip
      return nil if text.empty? && !required
      return reject("#{label} is required.") if text.empty?
      if text.match?(/[eE]/) || text.include?(".")
        return reject("Excel changed this #{label.downcase} into a number. Format the #{label} column as Text and type the 10 digits again.")
      end

      phone = Phone.normalise(text)
      return reject("#{label} must be a 10-digit mobile number.") unless phone.match?(/\A\+\d{10,15}\z/)

      phone
    end

    def parse_transaction(raw)
      value = raw.to_s.strip.downcase
      return value if %w[sale rent].include?(value)

      reject("Sale or rent must be sale or rent.")
    end

    def parse_budget(raw)
      text = raw.to_s.strip
      return reject("Budget is required.") if text.empty?
      return reject("Type the budget in rupees, for example 12000000.") if text.match?(/[a-zA-Z]/)

      cleaned = text.gsub(/[₹,\s]/, "")
      cleaned = cleaned.sub(/\.0+\z/, "") if cleaned.match?(/\A\d+\.0+\z/)
      return reject("Budget must be whole rupees, for example 12000000.") if cleaned.include?(".")
      return reject("Type the budget in rupees, for example 12000000.") unless cleaned.match?(/\A\d+\z/)

      amount = cleaned.to_i
      return reject("Budget must be greater than 0.") unless amount.positive?

      amount
    end

    def parse_property_type(raw, type)
      text = raw.to_s.strip
      if type == "rent"
        return reject("Leave Property type blank on a rent row.") if text.present?

        return nil
      end

      names = property_types.map(&:name)
      return reject("Property type is required. Use #{names.join(' or ')}.") if text.empty?

      found = property_types.find { |row| row.name.casecmp?(text) }
      return found if found

      reject("Property type must be #{names.join(' or ')}.")
    end

    def parse_email(raw)
      text = raw.to_s.strip
      return nil if text.empty?
      return reject("Email is not a valid email address.") unless text.match?(URI::MailTo::EMAIL_REGEXP)

      text.downcase
    end

    def parse_possession(raw)
      text = raw.to_s.strip
      return nil if text.empty?

      if text.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        return Date.iso8601(text)
      end
      if text.match?(/\A\d{1,2}[\/-]\d{1,2}[\/-]\d{4}\z/)
        day, month, year = text.split(/[\/-]/).map(&:to_i)
        return Date.new(year, month, day)
      end

      reject("Type the possession date as DD/MM/YYYY.")
    rescue Date::Error, ArgumentError
      reject("Type the possession date as DD/MM/YYYY.")
    end

    def parse_source(raw)
      text = raw.to_s.strip
      return nil if text.empty?

      found = lead_sources.find { |row| dash_label(row.name) == dash_label(text) }
      return found if found

      reject("Unknown source #{text}. Use one of: #{lead_sources.map(&:name).join(', ')}.")
    end

    def reject(message)
      Rejection.new(message)
    end

    def dash_label(value)
      value.to_s.tr("–—−", "-").gsub(/\s+/, " ").strip.downcase
    end

    def resolve_codes(raw, column)
      list = tokens(raw)
      if list.size > MAX_CODES
        label = column == :project ? "Project codes" : "Property codes"
        return reject("#{label} can list at most #{MAX_CODES} codes.")
      end

      found = []
      list.each do |token|
        resolved = column == :project ? resolve_project(token) : resolve_property(token)
        return reject(resolved) if resolved.is_a?(String)

        found << resolved
      end
      found.uniq(&:id)
    end

    def tokens(raw)
      raw.to_s.split(",").map(&:strip).compact_blank.uniq { |token| token.upcase }
    end

    def resolve_project(token)
      case token_kind(token)
      when :property_code
        "#{token.upcase} is a property code. Put it in Property codes."
      when :uuid
        return "#{token} is a property (#{property_visible(token).code}). Put it in Property codes." if property_visible(token)

        project_by_id(token)
      when :project_code
        project_by_code(token)
      when :launchiq
        project_by_external_ref(token)
      else
        "Unknown project code #{token}."
      end
    end

    def resolve_property(token)
      case token_kind(token)
      when :project_code
        "#{token.upcase} is a project code. Put it in Project codes."
      when :launchiq
        "#{token.upcase} is a project code. Put it in Project codes."
      when :uuid
        return "#{token} is a project (#{project_visible(token).code}). Put it in Project codes." if project_visible(token)

        property_by_id(token)
      when :property_code
        property_by_code(token)
      else
        "Unknown property code #{token}."
      end
    end

    def token_kind(token)
      return :uuid if token.match?(UUID)
      return :property_code if token.match?(/\AH-/i)
      return :project_code if token.match?(/\AP-/i)
      return :launchiq if token.match?(LAUNCHIQ_CODE)

      :other
    end

    def project_by_code(token)
      code = token.upcase
      own = Project.where("upper(code) = ?", code).first
      return gate_project(own) if own

      market = Project.marketplace.where("upper(code) = ?", code).first
      return market if market

      archived = Project.unscoped.where(firm_id: nil).where("upper(code) = ?", code).first
      return "That project is archived." if archived&.archived?

      "Unknown project code #{token}."
    end

    def project_by_id(token)
      own = Project.find_by(id: token)
      return gate_project(own) if own

      market = Project.marketplace.find_by(id: token)
      return market if market

      archived = Project.unscoped.find_by(id: token, firm_id: nil)
      return "That project is archived." if archived&.archived?

      "Unknown project code #{token}."
    end

    def project_by_external_ref(token)
      ref = token.upcase
      own = Project.where("upper(external_ref) = ?", ref).first
      if own
        return "That project is archived." if own.archived?

        return own
      end

      market = Project.marketplace.where("upper(external_ref) = ?", ref).first
      return market if market

      archived = Project.unscoped.where(firm_id: nil).where("upper(external_ref) = ?", ref).first
      return "That project is archived." if archived&.archived?

      "Unknown project code #{token}."
    end

    def gate_project(project)
      return "That project is archived." if project.archived?

      project
    end

    def project_visible(token)
      Project.find_by(id: token) ||
        Project.marketplace.find_by(id: token) ||
        Project.unscoped.find_by(id: token, firm_id: nil)
    end

    def property_by_code(token)
      code = token.upcase
      own = Property.where("upper(code) = ?", code).first
      return gate_property(own, shared: false) if own

      shared = shared_listing(code:)
      return gate_property(shared, shared: true) if shared

      "Unknown property code #{token}."
    end

    def property_by_id(token)
      own = Property.find_by(id: token)
      return gate_property(own, shared: false) if own

      shared = shared_listing(id: token)
      return gate_property(shared, shared: true) if shared

      "Unknown property code #{token}."
    end

    # The directory only lists another active firm's shared stock. A suspended
    # firm's code is reported as unknown, the same as a private code.
    def shared_listing(code: nil, id: nil)
      scope = Property.across_firms
        .joins(:firm)
        .where(listed_on_marketplace: true, firms: { status: "active" })
      scope = scope.where("upper(properties.code) = ?", code) if code
      scope = scope.where(properties: { id: }) if id
      scope.first
    end

    def gate_property(property, shared:)
      if shared
        return "That shared listing is not available." unless property.available?

        return property
      end
      return "That property is sold." if property.sold_out?

      property
    end

    def property_visible(token)
      Property.find_by(id: token) || shared_listing(id: token)
    end

    def codes_match_transaction(type, projects, properties)
      if type == "rent" && projects.any?
        return reject("Projects can only be linked to a sale lead. Leave Project codes blank, or mark the row as sale.")
      end

      properties.each do |property|
        next if property.listing_for == type

        return reject("#{property.code} is a #{property.listing_for} listing. This row is #{type}.")
      end
      nil
    end

    def resolve_typologies(raw, projects, properties)
      text = raw.to_s.strip
      if text.empty?
        ids = projects.flat_map(&:typology_ids) + properties.map(&:typology_id)
        ids = ids.compact.uniq
        return ids if ids.any?

        return reject("Add a configuration, such as 2 BHK.")
      end

      ids = []
      text.split(",").map(&:strip).compact_blank.each do |name|
        found = typologies.find { |row| squish(row.name) == squish(name) }
        return reject("Unknown configuration #{name}. Use one of: #{typologies.map(&:name).join(', ')}.") unless found

        ids << found.id
      end
      ids.uniq
    end

    def squish(value)
      value.to_s.gsub(/\s+/, "").downcase
    end

    def resolve_localities(raw, projects, properties)
      from_listings = projects.filter_map(&:locality_id) + properties.filter_map { |property| self.class.listing_building(property)&.locality_id }
      typed = parse_location_text(raw)
      return typed if typed.is_a?(Rejection)

      ids = (from_listings + typed).uniq
      return ids if ids.any?

      if raw.to_s.strip.empty? && (projects.any? || properties.any?)
        return reject("Add a location, such as Kharghar, Mumbai. None of the linked listings have one.")
      end

      reject("Location is required. Write it as Kharghar, Mumbai.")
    end

    def parse_location_text(raw)
      text = raw.to_s.strip
      return [] if text.empty?

      ids = []
      text.split(";").map(&:strip).compact_blank.each do |segment|
        resolved = one_location(segment)
        return reject(resolved) if resolved.is_a?(String)

        ids << resolved.id
      end
      ids
    end

    def one_location(segment)
      if segment.include?(",")
        parts = segment.split(",")
        right = parts.pop.to_s.strip
        left = parts.join(",").strip
        city = cities.find { |row| row.name.casecmp?(right) }
        if city
          locality = localities.find { |row| row.city_id == city.id && row.name.casecmp?(left) }
          return locality if locality

          return missing_locality(left, city)
        end

        return unique_locality(left) || unique_locality(segment) || "Unknown location #{segment}."
      end

      unique_locality(segment) || "Unknown location #{segment}."
    end

    def unique_locality(name)
      matches = localities.select { |row| row.name.casecmp?(name) }
      return nil if matches.empty?
      return matches.first if matches.one?

      listed = matches.first(8).map { |row| "#{row.name}, #{row.city.name}" }.join("; ")
      "#{name} matches more than one place: #{listed}."
    end

    def missing_locality(name, city)
      matches = localities.select { |row| row.city_id == city.id && row.name.downcase.include?(name.downcase) }
      suggestion = matches.first(8).map { |row| "#{row.name}, #{city.name}" }.join(" or ")
      message = "No locality named #{name} in #{city.name}."
      suggestion.present? ? "#{message} Did you mean #{suggestion}?" : message
    end

    def create_lead(prepared)
      ::Leads::Create.new(
        firm:, actor:,
        attributes: lead_attributes(prepared),
        typology_ids: prepared[:typologies],
        copy_project_typologies: false,
        locality_ids: prepared[:localities],
        copy_project_localities: false
      ).call
    end

    def lead_attributes(prepared)
      {
        name: prepared[:name],
        mobile: prepared[:mobile],
        alt_mobile: prepared[:alt_mobile],
        email: prepared[:email],
        transaction_type: prepared[:transaction_type],
        property_type_id: prepared[:property_type]&.id,
        budget: prepared[:budget],
        possession_by: prepared[:possession],
        lead_source_id: prepared[:source]&.id,
        source_detail: prepared[:source_detail],
        notes: prepared[:notes],
        assigned_user_id: actor.id
      }
    end

    def link(lead, prepared)
      prepared[:projects].each do |project|
        lead.lead_projects.create!(project:, firm:)
      end
      prepared[:properties].each do |property|
        lead.lead_properties.create!(property:, firm:)
      end
    end

    def failure_message(result, prepared)
      if result.error_code == "duplicate_lead"
        return duplicate_message(result, prepared[:transaction_type])
      end

      result.error_message.presence || result.errors&.full_messages&.to_sentence || "This row could not be imported."
    end

    def duplicate_message(result, type)
      existing_id = result.error_details&.dig(:lead_id) || result.error_details&.dig("lead_id")
      existing = existing_id && Lead.visible_to(actor).find_by(id: existing_id)
      if existing
        "A live #{type} lead already exists for this number (#{existing.code})."
      else
        "A live #{type} lead already exists for this number."
      end
    end

    def property_types
      @property_types ||= PropertyType.active.ordered.to_a
    end

    def lead_sources
      @lead_sources ||= LeadSource.active.ordered.to_a
    end

    def typologies
      @typologies ||= Typology.order(:sort_order, :name).to_a
    end

    def cities
      @cities ||= City.all.to_a
    end

    def localities
      @localities ||= Locality.includes(:city).to_a
    end
  end
end
