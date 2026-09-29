# frozen_string_literal: true

module Inventory
  # "2 BHK", "2BHK Ultima" and "2 BHK Compact" are the same configuration.
  # "2.5 BHK" is not, and "1 RK" is not "1 BHK".
  #
  # The key comes from the name. Typology#bedrooms cannot do this: 1 RK and
  # 1 BHK both store 1.0. Do not use Realtoriq::NameKey — that keeps
  # "2BHK Ultima" as its own key.
  module ConfigurationKey
    module_function

    def call(name)
      text = name.to_s.downcase
      if (match = text.match(/(\d+(?:\.\d+)?)\s*bhk/))
        "#{match[1].sub(/\.0\z/, '')}bhk"
      elsif text.match?(/\brk\b/)
        "1rk"
      elsif text.include?("villa")
        "villa"
      elsif text.include?("penthouse")
        "penthouse"
      else
        text.gsub(/[^a-z0-9]/, "")
      end
    end
  end
end
