# frozen_string_literal: true

module Api
  # Reads list-filter query params before they are bound. A value that is
  # present but can't be read as its type is an error message; a blank value
  # means the filter is off. Unknown parameter names are not this class's job.
  module ListParams
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
    WHOLE = /\A\d+\z/
    DECIMAL = /\A\d+(?:\.\d+)?\z/
    BOOLEAN_TEXT = /\A(?:true|false|1|0|t|f|on|off)\z/i
    BIGINT_MAX = 9_223_372_036_854_775_807
    DATE = Reports::Window::INVALID

    class << self
      # First problem, or nil. `rupees` and `areas` are whole numbers, 0 or
      # more, after spaces and commas are stripped. `decimals` are the same
      # with a fractional part allowed.
      def error(params, rupees: [], areas: [], decimals: [], dates: [], date_pairs: [], ids: [], booleans: [], enums: {}, per_page: false)
        (per_page ? check_per_page(params) : nil) ||
          check_numbers(params, rupees, :rupees) ||
          check_numbers(params, areas, :area) ||
          check_numbers(params, decimals, :decimal) ||
          check_dates(params, dates) ||
          check_date_pairs(params, date_pairs) ||
          check_ids(params, ids) ||
          check_booleans(params, booleans) ||
          check_enums(params, enums)
      end

      # Integer rupees, or nil when the value is blank or not a whole number.
      # Callers that already rejected a bad value still go through here so a
      # raw string is never bound into SQL.
      def whole_rupees(value)
        text = numeric_text(value)
        return if text.nil? || !WHOLE.match?(text)

        number = Integer(text, 10)
        number if number <= BIGINT_MAX
      end

      def decimal_number(value)
        text = numeric_text(value)
        return if text.nil? || !DECIMAL.match?(text)

        BigDecimal(text)
      end

      def numeric_text(value)
        return if value.nil?
        return value.to_s if value.is_a?(Integer) && value >= 0

        text = value.to_s.strip.gsub(/[\s,]/, "")
        text unless text.empty?
      end

      private

      def check_per_page(params)
        return unless params

        raw = params[:per_page]
        return if raw.nil? || raw == ""

        text = raw.is_a?(Integer) ? raw.to_s : raw.to_s.strip
        "per_page must be a whole number, 0 or more." unless WHOLE.match?(text)
      end

      def check_numbers(params, keys, kind)
        keys.each do |key|
          raw = params[key]
          next if raw.nil? || raw == ""

          cast = kind == :decimal ? decimal_number(raw) : whole_rupees(raw)
          next if cast

          return number_message(key, kind)
        end
        nil
      end

      def number_message(key, kind)
        case kind
        when :rupees
          label = key.to_s.start_with?("price") ? "Price" : "Budget"
          "#{label} must be a whole number of rupees, 0 or more."
        when :area
          "Area must be a whole number, 0 or more."
        else
          "Brokerage must be a number, 0 or more."
        end
      end

      def check_dates(params, keys)
        keys.each do |key|
          raw = params[key]
          next if raw.blank?
          return DATE unless Reports::Window.date?(raw)
        end
        nil
      end

      def check_date_pairs(params, pairs)
        pairs.each do |from_key, upto_key|
          from = params[from_key]
          upto = params[upto_key]
          next if from.blank? && upto.blank?
          return DATE if from.present? && !Reports::Window.date?(from)
          return DATE if upto.present? && !Reports::Window.date?(upto)
          next if from.blank? || upto.blank?
          return DATE if Date.iso8601(from.to_s) > Date.iso8601(upto.to_s)
        end
        nil
      end

      def check_ids(params, keys)
        keys.each do |key|
          tokens(params[key]).each do |token|
            return "#{key} must be an id." unless UUID.match?(token)
          end
        end
        nil
      end

      def check_booleans(params, keys)
        keys.each do |key|
          raw = params[key]
          next if raw.nil? || raw == ""

          text = raw.is_a?(TrueClass) || raw.is_a?(FalseClass) ? raw.to_s : raw.to_s.strip
          return "#{key} must be true or false." unless BOOLEAN_TEXT.match?(text)
        end
        nil
      end

      def check_enums(params, enums)
        enums.each do |key, spec|
          values, many, message = enum_spec(spec)
          raw = params[key]
          next if raw.blank?

          tokens = many ? tokens(raw) : [ raw.to_s.strip ]
          next if tokens.empty?

          allowed = values.respond_to?(:call) ? values.call : values
          next if tokens.all? { |token| allowed.include?(token) }

          return message || "#{key} must be #{allowed.to_sentence(two_words_connector: " or ", last_word_connector: ", or ")}."
        end
        nil
      end

      def enum_spec(spec)
        return [ spec, false, nil ] unless spec.is_a?(Hash)

        [ spec[:values], spec[:many] == true, spec[:message] ]
      end

      def tokens(value)
        Array(value).flatten.flat_map { |item| item.to_s.split(",") }.map(&:strip).reject(&:empty?)
      end
    end
  end
end
