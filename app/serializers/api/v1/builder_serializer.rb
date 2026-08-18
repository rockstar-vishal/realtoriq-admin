# frozen_string_literal: true

module Api
  module V1
    module BuilderSerializer
      def self.call(builder)
        {
          id: builder.id,
          name: builder.name,
          website: builder.website,
          # Tells the client whether this came from the platform's curated list
          # or the firm added it — the two are not equally trustworthy, and only
          # the firm's own are theirs to correct.
          global: builder.global?
        }
      end
    end
  end
end
