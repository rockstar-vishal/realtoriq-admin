# frozen_string_literal: true

module Realtoriq
  # "2 BHK", "2BHK" and "2-bhk" are the same configuration. Matching on the
  # raw name was creating a second global typology for every formatting variant.
  module NameKey
    module_function

    def call(name)
      name.to_s.downcase.gsub(/[^a-z0-9.]/, "")
    end
  end
end
