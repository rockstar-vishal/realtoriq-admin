# frozen_string_literal: true

module Marketing
  # The list a creative, a kit and the project detail all print. An empty
  # stored list falls back to the comma-separated rera_number.
  module Registrations
    def self.for(project)
      source = CatalogProject.for(project) || project
      rows = Array(source&.rera_registrations).filter_map { |row| entry(row) }
      return rows if rows.any?

      source&.rera_number.to_s.split(",").filter_map { |number|
        text = number.strip
        next if text.blank?

        { "number" => text, "label" => nil, "maharera_url" => nil }
      }
    end

    def self.entry(row)
      data = row.to_h.stringify_keys
      number = data["number"].to_s.strip
      return if number.blank?

      { "number" => number, "label" => data["label"].presence, "maharera_url" => data["maharera_url"].presence }
    end
  end
end
