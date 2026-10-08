# frozen_string_literal: true

module Matches
  # First argument is the firm id, so TenantJob can set Current.firm.
  # One run per firm at a time. A second enqueue waits, then no-ops if the
  # list was just written.
  class CurateFirmJob < TenantJob
    queue_as :matching

    limits_concurrency to: 1, key: ->(firm_id, *) { firm_id }, duration: 30.minutes

    def perform(firm_id)
      firm = Current.firm
      return if firm.nil? || firm.id != firm_id

      CurateFirm.call(firm:)
    end
  end
end
