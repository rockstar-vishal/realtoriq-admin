# frozen_string_literal: true

module Facebook
  # Facebook question → lead field. Budget, configuration and locality are
  # copied from the listing, not from the form.
  class FieldMapper
    TARGETS = %w[name mobile alt_mobile email notes ignore].freeze
    EMAIL_FORMAT = URI::MailTo::EMAIL_REGEXP

    STANDARD_MAPPINGS = {
      "full_name" => "name",
      "phone_number" => "mobile",
      "phone" => "mobile",
      "email" => "email"
    }.freeze

    KNOWN_SUGGESTIONS = STANDARD_MAPPINGS.merge(
      "first_name" => "name",
      "last_name" => "name",
      "email_address" => "email"
    ).freeze

    TARGET_OPTIONS = [
      [ "Ignore", "ignore" ],
      [ "Name", "name" ],
      [ "Mobile", "mobile" ],
      [ "Alt mobile", "alt_mobile" ],
      [ "Email", "email" ],
      [ "Notes", "notes" ]
    ].freeze

    SYNTHETIC_VALUES = {
      "name" => "Sample Name",
      "mobile" => "9820144210",
      "alt_mobile" => "9811111111",
      "email" => "sample@example.com",
      "notes" => "Sample answer"
    }.freeze

    Result = Struct.new(:name, :mobile, :alt_mobile, :email, :notes, :mobile_invalid, keyword_init: true)

    def self.sanitize_mappings(raw)
      hash = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
      (hash || {}).each_with_object({}) do |(key, value), out|
        next if key.blank?

        target = value.to_s.strip
        next if target.blank? || target == "ignore"
        next unless TARGETS.include?(target)

        out[key.to_s] = target
      end
    end

    def self.soft_fallback?(stored)
      sanitize_mappings(stored).empty?
    end

    def self.effective_mappings(stored)
      sanitize_mappings(stored).presence || STANDARD_MAPPINGS.dup
    end

    def self.suggested_mappings(questions)
      Array(questions).each_with_object({}) do |question, out|
        key = question_key(question)
        next if key.blank?

        suggested = KNOWN_SUGGESTIONS[key] || suggestion_from_type(question)
        out[key] = suggested if suggested
      end
    end

    def self.suggestion_from_type(question)
      case question_type(question)
      when "FULL_NAME", "FIRST_NAME", "LAST_NAME", "NAME" then "name"
      when "PHONE", "PHONE_NUMBER" then "mobile"
      when "EMAIL" then "email"
      end
    end

    def self.question_type(question)
      question.to_h.with_indifferent_access[:type].to_s.upcase.presence
    end

    def self.question_key(question)
      data = question.to_h.with_indifferent_access
      (data[:key].presence || data[:name]).to_s.presence
    end

    def self.question_label(question, fallback_key = nil)
      data = question.is_a?(Hash) ? question.with_indifferent_access : {}
      data[:label].presence || fallback_key.presence || question_key(data) || "Field"
    end

    def self.normalize_questions(raw_questions)
      Array(raw_questions).filter_map do |question|
        data = question.to_h.with_indifferent_access
        key = (data[:key].presence || data[:name]).to_s.presence
        next if key.blank?

        {
          "key" => key,
          "label" => (data[:label].presence || key).to_s,
          "type" => data[:type].to_s.presence
        }.compact
      end
    end

    def self.covers_name?(mappings)
      sanitize_mappings(mappings).value?("name")
    end

    def self.covers_mobile?(mappings)
      sanitize_mappings(mappings).value?("mobile")
    end

    def self.target_label(target)
      TARGET_OPTIONS.find { |_label, value| value == target.to_s }&.first || target.to_s
    end

    def self.extract_field_data(payload)
      field_data = {}
      Array(payload.to_h["field_data"] || payload.to_h[:field_data]).each do |field|
        data = field.to_h.with_indifferent_access
        values = Array(data[:values]).map { |value| value.to_s.strip }.reject(&:blank?)
        next if data[:name].blank? || values.empty?

        field_data[data[:name].to_s] = values.size == 1 ? values.first : values.join(", ")
      end
      field_data
    end

    def self.apply(field_data:, mappings:, questions: [])
      stored = sanitize_mappings(mappings)
      new(
        field_data: field_data,
        mappings: stored.presence || STANDARD_MAPPINGS,
        questions: questions,
        soft_fallback: stored.empty?
      ).apply
    end

    def self.synthetic_preview(mappings:, questions: [])
      effective = effective_mappings(mappings)
      field_data = Array(questions).each_with_object({}) do |question, out|
        key = question_key(question)
        next if key.blank?

        target = effective[key]
        next if target.blank? || target == "ignore"

        out[key] = SYNTHETIC_VALUES[target] || "Sample answer"
      end
      effective.each do |key, target|
        field_data[key] ||= SYNTHETIC_VALUES[target] || "Sample answer"
      end

      apply(field_data:, mappings: effective, questions:)
    end

    def initialize(field_data:, mappings:, questions: [], soft_fallback: false)
      @field_data = field_data.to_h.stringify_keys
      @mappings = mappings.stringify_keys
      @questions_by_key = Array(questions).each_with_object({}) do |question, index|
        key = self.class.question_key(question)
        index[key] = question if key.present?
      end
      @soft_fallback = soft_fallback
    end

    def apply
      name_parts = []
      note_lines = []
      mobile = nil
      alt_mobile = nil
      email = nil
      mobile_invalid = false

      @field_data.each do |key, value|
        next if value.blank?

        target = @mappings[key]
        next if target.blank? || target == "ignore"

        case target
        when "name"
          name_parts << value.to_s.strip
        when "mobile"
          mobile, invalid = self.class.normalise_mobile(value)
          mobile_invalid ||= invalid
        when "alt_mobile"
          alt_mobile, = self.class.normalise_mobile(value)
        when "email"
          candidate = value.to_s.strip.downcase
          email = candidate if candidate.match?(EMAIL_FORMAT)
        when "notes"
          label = self.class.question_label(@questions_by_key[key], key)
          note_lines << "#{label}: #{value}"
        end
      end

      if name_parts.empty? && @soft_fallback
        combined = [ @field_data["first_name"], @field_data["last_name"] ].compact.map { |part| part.to_s.strip }.reject(&:blank?)
        name_parts = combined if combined.any?
      end

      Result.new(
        name: name_parts.join(" ").strip.presence,
        mobile:,
        alt_mobile:,
        email:,
        notes: note_lines.join("\n").presence,
        mobile_invalid:
      )
    end

    # Returns [number, invalid]. invalid is true only when a value was present
    # and could not be kept. A blank value is neither.
    def self.normalise_mobile(value)
      return [ nil, false ] if value.blank?

      phone = Phone.normalise(value)
      return [ phone, false ] if phone&.match?(Lead::MOBILE_FORMAT)

      [ nil, true ]
    end
  end
end
