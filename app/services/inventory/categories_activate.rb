# frozen_string_literal: true

module Inventory
  # Run after the app that understands commercial and plot configurations
  # is live. Residential rows are already active.
  class CategoriesActivate
    def self.call(output: $stdout)
      codes = Typology::CANONICAL.reject { |row| row[:category] == "residential" }.map { |row| row[:code] }
      scope = Typology.where(code: codes, active: false, merged_into_id: nil)
      count = 0
      scope.find_each do |typology|
        typology.update!(active: true)
        count += 1
      end
      output.puts "Activated #{count} configurations"
      count
    end
  end
end
