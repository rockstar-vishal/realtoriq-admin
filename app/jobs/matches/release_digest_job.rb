# frozen_string_literal: true

module Matches
  class ReleaseDigestJob < TenantJob
    queue_as :matching

    limits_concurrency to: 1, key: ->(firm_id, *) { "release:#{firm_id}" }, duration: 10.minutes

    def perform(firm_id)
      firm = Current.firm
      return if firm.nil? || firm.id != firm_id

      ReleaseDigest.call(firm:)
    end
  end
end
