# frozen_string_literal: true

module Api
  module V1
    module LeadFollowupSerializer
      def self.call(followup)
        {
          id: followup.id,
          comment: followup.comment,
          next_action_at: followup.next_action_at,
          user: followup.user && { id: followup.user_id, name: followup.user.name },
          created_at: followup.created_at
        }
      end
    end
  end
end
