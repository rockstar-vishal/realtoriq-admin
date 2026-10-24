# frozen_string_literal: true

module Matches
  # Turns anchor matching off and rebuilds same-city neighbor pairs. Nearby
  # matching is left as it was. Digests are rewritten without a notification.
  class DisableAnchors
    def self.call
      new.call
    end

    def call
      firms = Eligible.firms.to_a
      locked = []
      begin
        firms.each do |firm|
          ScanLock.lock(firm)
          locked << firm
        end
        ::AnchorMatching.disable!
        Locality.distinct.pluck(:city_id).each do |city_id|
          Inventory::RebuildLocalityNeighbors.call(city_id:)
        end
        locked.each do |firm|
          Current.set(firm:) { CurateFirm.call(firm:, announce: false) }
        end
      ensure
        locked.each { |firm| ScanLock.unlock(firm) }
      end
    end
  end
end
