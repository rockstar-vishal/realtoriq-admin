# frozen_string_literal: true

module Realtoriq
  # Runs after the upsert commits. A catalog row has no firm, so the job
  # bypasses the tenant scope that would otherwise hide it.
  class SyncProjectAssetsJob < ApplicationJob
    queue_as :marketplace_assets

    # One project's files at a time. A second push waits, then copies whatever
    # is current, instead of downloading the same set twice.
    limits_concurrency to: 1, key: ->(project_id, *) { project_id }, duration: 15.minutes

    retry_on RemoteFile::Error, wait: :polynomially_longer, attempts: 5

    def perform(project_id, images, brochure, pushed_at = nil, brokerage_ladder = nil)
      Current.set(firm_scope_bypassed: true) do
        project = Project.unscoped.find_by(id: project_id)
        return if project.nil?

        SyncProjectAssets.call(
          project:, images:, brochure:, pushed_at: parse_time(pushed_at), brokerage_ladder:
        )
      end
    end

    def parse_time(value)
      return if value.blank?

      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
