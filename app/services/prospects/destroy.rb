# frozen_string_literal: true

module Prospects
  # Hard-deletes one prospect. The linked lead is left in the pipeline.
  class Destroy
    Result = Struct.new(:ok?, :error_code, :error_message, keyword_init: true)

    def initialize(prospect:, actor:)
      @prospect = prospect
      @actor = actor
    end

    def call
      unless prospect.manager_can_delete?(actor)
        return Result.new(ok?: false, error_code: "forbidden_role",
          error_message: "Only a manager can delete prospects.")
      end

      Prospect.transaction do
        locked = Prospect.lock.find(prospect.id)
        AuditEvent.record!(
          subject: locked, action: "prospect_deleted", actor:, firm: locked.firm,
          metadata: { status: locked.status }
        )
        locked.destroy!
      end
      Result.new(ok?: true)
    end

    private

    attr_reader :prospect, :actor
  end
end
