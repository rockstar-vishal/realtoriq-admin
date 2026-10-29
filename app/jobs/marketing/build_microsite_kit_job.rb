# frozen_string_literal: true

module Marketing
  class BuildMicrositeKitJob < ApplicationJob
    queue_as :default

    def perform(kit_id)
      kit = MicrositeKit.across_firms.find_by(id: kit_id)
      return if kit.nil? || !kit.preparing?

      Current.set(firm: kit.firm) do
        BuildMicrositeKit.call(kit)
      end
    rescue StandardError => error
      Rails.logger.error("Microsite kit failed (#{kit_id}): #{error.class}: #{error.message}")
      kit&.update!(status: "failed", error_message: error.message.to_s.truncate(300))
    end
  end
end
