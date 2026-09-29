# frozen_string_literal: true

# A job whose first argument is a firm id. FirmScoped models find nothing
# unless Current.firm is set, and a job has no request to set it.
class TenantJob < ApplicationJob
  self.enqueue_after_transaction_commit = true

  around_perform do |job, block|
    firm = Firm.find(job.arguments.first)
    Current.set(firm:) { block.call }
  end
end
