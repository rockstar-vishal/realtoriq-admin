# frozen_string_literal: true

require "csv"

module Prospects
  # One CSV, one prospect per row. A bad row is reported and does not undo the
  # rows already added. The firm row stays locked for the whole file so two
  # imports cannot both pass the 5,000 cap.
  class Import
    MAX_ROWS = Prospect::MAX_PER_FIRM
    EXAMPLE_NAME = "example caller"
    EXAMPLE_MOBILE_DIGITS = "9000000000"
    EXAMPLE_ONLY = "The example row was skipped. Replace Example caller with your own clients and import that file."
    XLSX_MAGIC = "PK\x03\x04".b

    HEADERS = [
      [ :name, "Client name" ],
      [ :mobile, "Client number" ],
      [ :comment, "Comment" ],
      [ :project_code, "Project code" ],
      [ :property_code, "Property code" ]
    ].freeze

    HEADER_ALIASES = {
      "name" => :name,
      "client" => :name,
      "phone" => :mobile,
      "mobile" => :mobile,
      "number" => :mobile,
      "client mobile" => :mobile,
      "notes" => :comment,
      "note" => :comment,
      "project" => :project_code,
      "property" => :property_code
    }.freeze

    Result = Struct.new(:file_error, :created_count, :failed_count, :results, keyword_init: true) do
      def as_json(*)
        { created_count:, failed_count:, results: }
      end
    end

    def self.template
      CSV.generate do |csv|
        csv << HEADERS.map(&:last)
        csv << [ "Example caller", "9000000000", "Asked for a 2 BHK", nil, nil ]
      end
    end

    def initialize(firm:, actor:, io:)
      @firm = firm
      @actor = actor
      @io = io
      @seen = {}
    end

    def call
      parsed = parse_sheet
      return file_result(parsed) if parsed.is_a?(String)

      rows, skipped_example = parsed
      if rows.empty?
        return file_result(skipped_example ? EXAMPLE_ONLY : "The file has no prospects to import.")
      end
      if rows.size > MAX_ROWS
        return file_result("A file can have at most #{MAX_ROWS} prospects. Split this one and import it in parts.")
      end

      results = firm.with_lock do
        remember_existing
        rows.map { |row| import_row(row) }
      end
      Result.new(
        created_count: results.count { |row| row[:status] == "created" },
        failed_count: results.count { |row| row[:status] == "failed" },
        results:
      )
    end

    private

    attr_reader :firm, :actor, :io, :seen

    def file_result(message)
      Result.new(file_error: message, created_count: 0, failed_count: 0, results: [])
    end

    def parse_sheet
      raw = io.to_s.dup.force_encoding(Encoding::BINARY)
      return "This is an Excel workbook. Save it as CSV UTF-8 (comma separated) and upload that file." if raw.start_with?(XLSX_MAGIC)

      text = raw.force_encoding(Encoding::UTF_8)
      return "This file could not be read. Save it as CSV UTF-8 (comma separated) and upload that." unless text.valid_encoding?

      text = text.sub(/\A\uFEFF/, "")
      return "This file uses semicolons. Save it as CSV UTF-8 (comma separated) and upload that." if semicolon_file?(text)
      return "The file is empty." if text.strip.empty?

      table = CSV.parse(text, headers: true)
      return "The file is empty." if table.headers.compact.empty?

      missing = required_header_missing(table.headers)
      return "The file is missing a #{missing} column." if missing

      rows = []
      skipped_example = false
      table.each.with_index(2) do |csv_row, line|
        fields = extract(csv_row)
        if example_row?(fields)
          skipped_example = true
          next
        end
        next if blank_fields?(fields)

        rows << { line:, fields:, cells: cells_for(fields) }
      end
      [ rows, skipped_example ]
    rescue CSV::MalformedCSVError
      "This file could not be read. Save it as CSV UTF-8 (comma separated) and upload that."
    end

    def semicolon_file?(text)
      first = text.lines.first.to_s
      first.count(";").positive? && first.count(",").zero?
    end

    def required_header_missing(headers)
      keys = headers.filter_map { |header| header_key(header) }
      return "Client number" unless keys.include?(:mobile)

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
        fields[:mobile].to_s.gsub(/\D/, "").sub(/\A0+/, "").then { |digits|
          digits == EXAMPLE_MOBILE_DIGITS || digits == "91#{EXAMPLE_MOBILE_DIGITS}"
        }
    end

    def import_row(row)
      prepared = prepare(row[:fields])
      return failure(row, prepared) if prepared.is_a?(String)

      if seen[prepared[:mobile]]
        return failure(row, "This number is already in this file.")
      end
      if @known_mobiles.key?(prepared[:mobile])
        return failure(row, "This number is already in your list.")
      end
      if @held >= Prospect::MAX_PER_FIRM
        return failure(row, "Your firm already has #{Prospect::MAX_PER_FIRM} prospects.")
      end

      prospect = Prospect.new(
        firm:, created_by: actor, name: prepared[:name], mobile: prepared[:mobile],
        comment: prepared[:comment], project: prepared[:project], property: prepared[:property],
        status: "new"
      )
      prospect.firm_cap_reserved = true
      Prospect.transaction(requires_new: true) { prospect.save! }
      seen[prepared[:mobile]] = true
      @known_mobiles[prepared[:mobile]] = true
      @held += 1
      {
        row: row[:line], status: "created", name: prepared[:name], mobile: row[:fields][:mobile].to_s.strip,
        prospect_id: prospect.id, error: nil, cells: row[:cells]
      }
    rescue ActiveRecord::RecordInvalid => e
      failure(row, e.record.errors.full_messages.to_sentence)
    rescue ActiveRecord::RecordNotUnique
      failure(row, "This number is already in your list.")
    end

    def prepare(fields)
      extracted = Phone.extract_indian_mobile(fields[:mobile])
      return extracted.error unless extracted.ok?

      name = fields[:name].to_s.strip.presence
      return "Client name is too long." if name && name.length > Prospect::NAME_MAX

      comment = fields[:comment].to_s.strip.presence
      return "Comment is too long." if comment && comment.length > Prospect::COMMENT_MAX

      project_token = fields[:project_code].to_s.strip
      property_token = fields[:property_code].to_s.strip
      return "A row can have a project code or a property code, not both." if project_token.present? && property_token.present?

      project = resolve_project(project_token)
      return project if project.is_a?(String)

      property = resolve_property(property_token)
      return property if property.is_a?(String)

      { name:, mobile: extracted.mobile, comment:, project:, property: }
    end

    def firm_prospects
      Prospect.unscoped.where(firm_id: firm.id)
    end

    # One read of the mobiles already on the list, then a running tally. The
    # firm row stays locked so a second import cannot pass the same cap.
    def remember_existing
      @known_mobiles = firm_prospects.pluck(:mobile).index_with(true)
      @held = @known_mobiles.size
      @resolved_projects = {}
      @resolved_properties = {}
    end

    def resolve_project(token)
      cache_code(@resolved_projects, token) { |key| Inventory.project_by_code(key) }
    end

    def resolve_property(token)
      cache_code(@resolved_properties, token) { |key| Inventory.property_by_code(key) }
    end

    def cache_code(cache, token)
      return if token.blank?

      key = token.to_s.strip
      return cache[key] if cache.key?(key)

      cache[key] = yield(key)
    end

    def failure(row, message)
      {
        row: row[:line], status: "failed", name: row[:fields][:name].to_s.strip.presence,
        mobile: row[:fields][:mobile].to_s.strip, prospect_id: nil, error: message, cells: row[:cells]
      }
    end
  end
end
