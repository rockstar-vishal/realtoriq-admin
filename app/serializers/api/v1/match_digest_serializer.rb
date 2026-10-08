# frozen_string_literal: true

module Api
  module V1
    module MatchDigestSerializer
      def self.call(digest)
        {
          generated_at: digest.generated_at,
          lead_items: without_ids(digest.lead_items),
          listing_items: without_ids(digest.listing_items)
        }
      end

      def self.without_ids(items)
        Array(items).map { |item| item.except("match_ids") }
      end
      private_class_method :without_ids
    end
  end
end
