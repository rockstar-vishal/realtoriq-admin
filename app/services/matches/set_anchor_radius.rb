# frozen_string_literal: true

module Matches
  # Changes the anchor radius and rewrites digests quietly. Refuses a value
  # outside 1,000–6,000 metres, and refuses to run while the switch is off.
  class SetAnchorRadius
    RANGE = 1_000..6_000

    def self.call(metres:)
      new(metres:).call
    end

    def initialize(metres:)
      @metres = Integer(metres)
    end

    def call
      raise ArgumentError, "Radius must be between 1000 and 6000" unless RANGE.cover?(metres)
      raise ArgumentError, "Anchor matching is off" unless ::AnchorMatching.enabled?

      firms = Eligible.firms.to_a
      locked = []
      begin
        firms.each do |firm|
          ScanLock.lock(firm)
          locked << firm
        end
        ::AnchorMatching.set_radius!(metres)
        locked.each do |firm|
          Current.set(firm:) { CurateFirm.call(firm:, announce: false) }
        end
      ensure
        locked.each { |firm| ScanLock.unlock(firm) }
      end
    end

    private

    attr_reader :metres
  end
end
