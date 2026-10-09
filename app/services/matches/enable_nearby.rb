# frozen_string_literal: true

module Matches
  # Turns nearby matching on after centers exist. Digests are rewritten first
  # and the notification fingerprint is set to that list, so the switch itself
  # does not ping anyone.
  class EnableNearby
    def self.call
      new.call
    end

    def call
      Locality.distinct.pluck(:city_id).each do |city_id|
        Inventory::RebuildLocalityNeighbors.call(city_id:)
      end

      # Lock every eligible firm before the flag flips. A scan that is already
      # running finishes on exact localities. A scan that starts after the flag
      # waits until this firm's quiet digest is written, so it does not notify.
      firms = Eligible.firms.to_a
      locked = []
      begin
        firms.each do |firm|
          ScanLock.lock(firm)
          locked << firm
        end
        ::NearbyMatching.enable!
        locked.each do |firm|
          Current.set(firm:) { CurateFirm.call(firm:, announce: false) }
        end
      ensure
        locked.each { |firm| ScanLock.unlock(firm) }
      end
    end
  end
end
