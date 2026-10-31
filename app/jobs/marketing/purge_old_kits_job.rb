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
      purge_expired_copies
    end

    private

    def purge(scope)
      scope.find_each(batch_size: 200) do |kit|
        kit.file.purge_later if kit.file.attached?
        kit.destroy!
      end
    end

    # Valid Until is the last day a creative is offered. Copies stay for
    # seven days after that date, then the files and rows go. The count is
    # the only thing written to the log.
    def purge_expired_copies
      cutoff = Time.find_zone!("Asia/Kolkata").today - 7
      scope = PersonalisedCreative.across_firms.joins(:project_creative).where(project_creatives: { valid_until: ...cutoff })
      count = 0
      scope.find_each(batch_size: 200) do |copy|
        copy.file.purge_later if copy.file.attached?
        copy.destroy!
        count += 1
      end
      Rails.logger.info("Expired personalised creatives purged: #{count}")
    end
  end
end
