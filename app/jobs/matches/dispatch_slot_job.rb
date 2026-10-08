# frozen_string_literal: true

module Matches
  # Scheduled every hour on staging and production. Development has no queue
  # database; run Matches::DispatchSlot.call from a console there.
  class DispatchSlotJob < ApplicationJob
    def perform
      DispatchSlot.call
    end
  end
end
