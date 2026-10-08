# frozen_string_literal: true

module Prospects
  # Hard-deletes every prospect in the chosen statuses. Leads stay.
  class Clear
    Result = Struct.new(:ok?, :deleted_count, :error_code, :error_message, keyword_init: true)

    def initialize(firm:, actor:, statuses:)
      @firm = firm
      @actor = actor
      @statuses = Array(statuses).map(&:to_s) & Prospect::STATUSES
    end

    def call
      unless actor.super_admin? || actor.manager?
        return Result.new(ok?: false, error_code: "forbidden_role",
          error_message: "Only a manager can clear prospects.")
      end
      if statuses.empty?
        return Result.new(ok?: false, error_code: "invalid",
          error_message: "Choose at least one status to clear.")
      end

      deleted = firm.with_lock do
        ids = Prospect.where(status: statuses).pluck(:id)
        ProspectFollowup.where(prospect_id: ids).delete_all
        Prospect.where(id: ids).delete_all
        AuditEvent.record!(
          subject: firm, action: "prospects_cleared", actor:, firm:,
          metadata: { statuses:, count: ids.size }
        )
        ids.size
      end
      Result.new(ok?: true, deleted_count: deleted)
    end

    private

    attr_reader :firm, :actor, :statuses
  end
end
