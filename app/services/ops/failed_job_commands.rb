# frozen_string_literal: true

module Ops
  # The two server commands quoted in the alert email. docs/operations.md
  # carries the same lines.
  module FailedJobCommands
    LOOK = "bin/rails runner 'SolidQueue::FailedExecution.includes(:job).order(:created_at).find_each { |row| " \
      "puts [row[:id], row.job.class_name, row.exception_class].join(\" \") }'"

    RETRY_OR_DISCARD = "bin/rails runner 'row = SolidQueue::FailedExecution.find(ID); row.retry # or: row.discard'"
  end
end
