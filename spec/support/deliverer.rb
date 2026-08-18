# frozen_string_literal: true

# Captures codes instead of sending them, so specs can assert on what would
# have gone out — and read the plaintext, which is unrecoverable once issued.
class SpyDeliverer < Notifications::Deliverer
  Delivery = Struct.new(:transport, :destination, :code, :purpose, keyword_init: true)

  attr_reader :deliveries

  def initialize
    @deliveries = []
  end

  def deliver_code(transport:, destination:, code:, purpose:)
    @deliveries << Delivery.new(transport:, destination:, code:, purpose:)
    true
  end

  def last = deliveries.last

  # Simulates a provider outage.
  class Failing < Notifications::Deliverer
    def deliver_code(**)
      raise Notifications::Deliverer::DeliveryError, "provider unreachable"
    end
  end
end

RSpec.configure do |config|
  config.before do
    @spy_deliverer = SpyDeliverer.new
    Notifications::Deliverer.current = @spy_deliverer
  end

  config.after { Notifications::Deliverer.current = nil }
end

module DelivererHelpers
  def deliverer = @spy_deliverer
end

RSpec.configure { |config| config.include DelivererHelpers }
