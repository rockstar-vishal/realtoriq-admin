# frozen_string_literal: true

module Form6
  # The firm's Form 6 answers. Unknown keys are dropped. A person object
  # replaces that person: a field left out is cleared.
  class Settings
    STRING_LIMITS = {
      "registered_name" => 160,
      "competency_certificate_no" => 80,
      "signatory_name" => 120,
      "signatory_designation" => 80
    }.freeze
    PERSONS = %w[principal_officer designated_director].freeze
    PERSON_FIELDS = %w[name appointed_on mobile email address].freeze
    NAME_LIMIT = 120
    ADDRESS_LIMIT = 300
    EMAIL_LIMIT = 160
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
    MOBILE = /\A\+91[6-9]\d{9}\z/

    Result = Struct.new(:ok?, :settings, :message, :details, keyword_init: true)

    class << self
      def apply(firm:, incoming:)
        new(firm:, incoming: incoming.to_h).apply
      end

      def payload(firm)
        data = read(firm)
        {
          registered_name: data["registered_name"],
          competency_certificate_no: data["competency_certificate_no"],
          signatory_name: data["signatory_name"],
          signatory_designation: data["signatory_designation"],
          designated_project_ids: Array(data["designated_project_ids"]),
          turnover_20l_or_more: data["turnover_20l_or_more"] == true,
          principal_officer: person_payload(data["principal_officer"]),
          designated_director: person_payload(data["designated_director"]),
          firm_rera_number: firm.rera_number,
          firm_legal_name: firm.legal_name,
          available: firm.form6_available?,
          periods: Period.completed.map(&:as_json)
        }
      end

      # Keys that will leave a blank on the form. The agent's name falls back
      # to the legal name and the firm name, so an empty registered_name is
      # not a gap. Table C is only a gap when the firm says turnover is
      # ₹20 lakh or more.
      def missing_keys(firm)
        data = read(firm)
        keys = %w[competency_certificate_no signatory_name signatory_designation].select { |key| data[key].blank? }
        return keys unless data["turnover_20l_or_more"] == true

        PERSONS.each do |person|
          fields = data[person].is_a?(Hash) ? data[person].stringify_keys : {}
          PERSON_FIELDS.each { |field| keys << "#{person}.#{field}" if fields[field].blank? }
        end
        keys
      end

      def read(firm)
        raw = firm.form6
        raw.is_a?(Hash) ? raw.stringify_keys : {}
      end

      def agent_name(firm)
        data = read(firm)
        data["registered_name"].presence || firm.legal_name.presence || firm.name.presence
      end

      # The firm's own projects, plus a LaunchIQ catalog project the developer
      # designated this agent on before the firm has a copy. Another firm's
      # project is not in either set.
      def projects_for(firm, ids)
        ids = Array(ids)
        return {} if ids.empty?

        found = {}
        firm.projects.where(id: ids).each { |project| found[project.id.to_s.downcase] = project }
        Project.unscoped.where(id: ids, firm_id: nil, source: "catalog").each do |project|
          found[project.id.to_s.downcase] = project
        end
        found
      end

      def person_payload(value)
        value = value.stringify_keys if value.is_a?(Hash)
        value = {} unless value.is_a?(Hash)
        PERSON_FIELDS.index_with { |field| value[field] }
      end
    end

    def initialize(firm:, incoming:)
      @firm = firm
      @incoming = incoming.stringify_keys
      @errors = {}
      @settings = self.class.read(firm).slice(*stored_keys)
    end

    def apply
      copy_strings
      copy_projects
      copy_turnover
      copy_people
      return failure if errors.any?

      Result.new(ok?: true, settings: compact(settings))
    end

    private

    attr_reader :firm, :incoming, :errors, :settings

    def stored_keys
      STRING_LIMITS.keys + [ "designated_project_ids", "turnover_20l_or_more" ] + PERSONS
    end

    def copy_strings
      STRING_LIMITS.each do |key, limit|
        next unless incoming.key?(key)

        state, value = text(incoming[key], limit:)
        case state
        when :ok then settings[key] = value
        when :clear then settings.delete(key)
        when :error then errors[key] = [ value ]
        end
      end
    end

    def copy_projects
      return unless incoming.key?("designated_project_ids")

      ids, message = project_ids(incoming["designated_project_ids"])
      if message
        errors["designated_project_ids"] = [ message ]
      else
        settings["designated_project_ids"] = ids
      end
    end

    def copy_turnover
      return unless incoming.key?("turnover_20l_or_more")

      value = boolean(incoming["turnover_20l_or_more"])
      if value.nil?
        errors["turnover_20l_or_more"] = [ "must be true or false" ]
      else
        settings["turnover_20l_or_more"] = value
      end
    end

    def copy_people
      PERSONS.each do |key|
        next unless incoming.key?(key)

        value = incoming[key]
        if value.nil?
          settings.delete(key)
        elsif !value.is_a?(Hash)
          errors[key] = [ "must be an object" ]
        else
          person, person_errors = person_from(value.stringify_keys)
          person_errors.each { |field, message| errors["#{key}.#{field}"] = [ message ] }
          settings[key] = person if person_errors.empty?
        end
      end
    end

    def person_from(value)
      person = {}
      field_errors = {}
      copy_person_text(person, field_errors, value, "name", NAME_LIMIT)
      copy_person_date(person, field_errors, value, "appointed_on")
      copy_person_mobile(person, field_errors, value, "mobile")
      copy_person_email(person, field_errors, value, "email")
      copy_person_text(person, field_errors, value, "address", ADDRESS_LIMIT)
      [ person, field_errors ]
    end

    def copy_person_text(person, field_errors, value, field, limit)
      return unless value.key?(field)

      state, cleaned = text(value[field], limit:)
      person[field] = cleaned if state == :ok
      field_errors[field] = cleaned if state == :error
    end

    def copy_person_date(person, field_errors, value, field)
      return unless value.key?(field)

      state, cleaned = date_text(value[field])
      person[field] = cleaned if state == :ok
      field_errors[field] = cleaned if state == :error
    end

    def copy_person_mobile(person, field_errors, value, field)
      return unless value.key?(field)

      state, cleaned = mobile_text(value[field])
      person[field] = cleaned if state == :ok
      field_errors[field] = cleaned if state == :error
    end

    def copy_person_email(person, field_errors, value, field)
      return unless value.key?(field)

      state, cleaned = email_text(value[field])
      person[field] = cleaned if state == :ok
      field_errors[field] = cleaned if state == :error
    end

    def project_ids(value)
      return [ [], "must be a list of projects" ] unless value.is_a?(Array)

      ids = value.map { |id| id.to_s.strip }
      return [ [], "must be project ids" ] if ids.any? { |id| !id.match?(UUID) }

      found = self.class.projects_for(firm, ids)
      return [ [], "isn't one of this firm's projects" ] if ids.any? { |id| found[id.downcase].nil? }

      seen = {}
      ordered = ids.filter_map do |id|
        canonical = found[id.downcase].id.to_s
        next if seen[canonical]

        seen[canonical] = true
        canonical
      end
      [ ordered, nil ]
    end

    def text(value, limit:)
      return [ :clear, nil ] if value.nil?
      return [ :error, "must be text" ] unless value.is_a?(String)

      cleaned = value.strip
      return [ :clear, nil ] if cleaned.empty?
      return [ :error, "is too long (maximum is #{limit} characters)" ] if cleaned.length > limit

      [ :ok, cleaned ]
    end

    def date_text(value)
      return [ :clear, nil ] if value.nil? || value.is_a?(String) && value.strip.empty?
      return [ :error, "must be a date" ] unless value.is_a?(String)

      [ :ok, Date.iso8601(value).iso8601 ]
    rescue Date::Error, ArgumentError
      [ :error, "must be a date" ]
    end

    def mobile_text(value)
      return [ :clear, nil ] if value.nil? || value.is_a?(String) && value.strip.empty?
      return [ :error, "must be an Indian mobile number" ] unless value.is_a?(String)

      normalised = Phone.normalise(value)
      return [ :error, "must be an Indian mobile number" ] unless normalised.to_s.match?(MOBILE)

      [ :ok, normalised ]
    end

    def email_text(value)
      return [ :clear, nil ] if value.nil? || value.is_a?(String) && value.strip.empty?
      return [ :error, "must be an email" ] unless value.is_a?(String)

      cleaned = value.strip.downcase
      return [ :error, "must be an email" ] unless cleaned.match?(URI::MailTo::EMAIL_REGEXP)
      return [ :error, "is too long (maximum is #{EMAIL_LIMIT} characters)" ] if cleaned.length > EMAIL_LIMIT

      [ :ok, cleaned ]
    end

    def boolean(value)
      case value
      when true, false then value
      when "true" then true
      when "false" then false
      end
    end

    def compact(hash)
      hash.each_with_object({}) do |(key, value), out|
        case value
        when nil, ""
          next
        when Hash
          person = compact(value)
          out[key] = person if person.present?
        when Array
          out[key] = value if value.any?
        else
          out[key] = value
        end
      end
    end

    def failure
      Result.new(ok?: false, message: "Form 6 settings are invalid.", details: errors)
    end
  end
end
