# frozen_string_literal: true

module Facebook
  # Drops old login attempts and imports that have already been handled.
  # Failed and pending rows stay until someone retries them or they die.
  class CleanupJob < ApplicationJob
    def perform
      FacebookOauthAttempt.across_firms.where(created_at: ...1.day.ago).delete_all
      FacebookLeadImport.across_firms.where(status: "dead", updated_at: ...30.days.ago).delete_all
      FacebookLeadImport.across_firms.where(status: %w[created duplicate], updated_at: ...180.days.ago).delete_all
    end
  end
end
