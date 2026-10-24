# frozen_string_literal: true

module Matches
  # Turns anchor matching on. Nearby matching comes on with it. Digests are
  # rewritten with the notified fingerprint set to that list, so the switch
  # itself does not ping anyone. Firms are locked before the flag flips.
  class EnableAnchors
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
        ::AnchorMatching.enable!
        ::NearbyMatching.enable! unless ::NearbyMatching.enabled?
        Inventory::RebuildLocalityNeighbors.rebuild_all(across_cities: true)
        locked.each do |firm|
          Current.set(firm:) { CurateFirm.call(firm:, announce: false) }
        end
      ensure
        locked.each { |firm| ScanLock.unlock(firm) }
      end
    end
  end
end
