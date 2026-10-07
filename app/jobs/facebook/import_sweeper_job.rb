# frozen_string_literal: true

module Facebook
  # Picks up imports the worker never finished. Runs across firms. Does not
  # lift the tenant scope; each import is handed to a tenant job.
  class ImportSweeperJob < ApplicationJob
    def perform
      reenqueue_pending
      reenqueue_failed
      reset_stuck_processing
    end

    private

    def reenqueue_pending
      FacebookLeadImport.across_firms.where(status: "pending").where(created_at: ...10.minutes.ago)
        .where("next_attempt_at IS NULL OR next_attempt_at <= ?", Time.current)
        .find_each { |row| enqueue_once(row) }
    end

    def reenqueue_failed
      FacebookLeadImport.across_firms.where(status: "failed").where(next_attempt_at: ...10.minutes.ago)
        .find_each { |row| enqueue_once(row) }
    end

    def reset_stuck_processing
      FacebookLeadImport.across_firms.where(status: "processing")
        .where(processing_started_at: ...15.minutes.ago).find_each do |row|
        updated = FacebookLeadImport.across_firms.where(id: row.id, status: "processing").update_all(
          status: "pending",
          next_attempt_at: 10.minutes.from_now,
          updated_at: Time.current
        )
        ProcessLeadJob.perform_later(row.firm_id, row.id) if updated == 1
      end
    end

    # Push the next sweep out so a stopped queue does not stack a job every run.
    def enqueue_once(row)
      claimed = FacebookLeadImport.across_firms.where(id: row.id, status: row.status).update_all(
        next_attempt_at: 10.minutes.from_now,
        updated_at: Time.current
      )
      ProcessLeadJob.perform_later(row.firm_id, row.id) if claimed == 1
    end
  end
end
