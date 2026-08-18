# frozen_string_literal: true

module Api
  module V1
    module LeadActivitySerializer
      def self.call(activity)
        {
          id: activity.id,
          kind: activity.kind,
          body: activity.body,
          outcome: activity.outcome,
          occurred_at: activity.occurred_at,
          # `system` marks the rows the app wrote itself, so the client can
          # render them differently from something a person typed.
          system: activity.status_change?,
          user: activity.user && { id: activity.user_id, name: activity.user.name },
          created_at: activity.created_at
        }
      end
    end
  end
end
