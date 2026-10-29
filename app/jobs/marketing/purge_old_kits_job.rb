# frozen_string_literal: true

module Marketing
  # Drops kits a firm is no longer likely to re-download. The next tap builds
  # a fresh one. Files go through purge_later so a large zip is not deleted
  # inside the daily pass.
  class PurgeOldKitsJob < ApplicationJob
    queue_as :default

    def perform
      purge(MicrositeKit.across_firms.where(created_at: ..30.days.ago))
      purge(MicrositeKit.across_firms.where(status: "failed", created_at: ..1.day.ago))
    end

    private

    def purge(scope)
      scope.find_each(batch_size: 200) do |kit|
        kit.file.purge_later if kit.file.attached?
        kit.destroy!
      end
    end
  end
end
