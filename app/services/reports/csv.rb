# frozen_string_literal: true

require "csv"

module Reports
  # Same numbers as the JSON table. A cell that starts with a spreadsheet
  # formula character is quoted so a source name cannot become a formula.
  class Csv
    def self.generate(headers, rows)
      ::CSV.generate do |csv|
        csv << headers
        rows.each { |row| csv << row.map { |cell| sanitize(cell) } }
      end
    end

    def self.sanitize(cell)
      text = cell.nil? ? "" : cell.to_s
      text.match?(/\A[=+\-@]/) ? "'#{text}" : text
    end
  end
end
