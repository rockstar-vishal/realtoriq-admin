# frozen_string_literal: true

module Matches
  # Rewrites every eligible firm's digest after the category rules change.
  # The notified fingerprint is set to that list, so the deploy itself does
  # not tell brokers they have new matches.
  class Rebaseline
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
        locked.each do |firm|
          Current.set(firm:) { CurateFirm.call(firm:, announce: false) }
        end
      ensure
        locked.each { |firm| ScanLock.unlock(firm) }
      end
    end
  end
end
