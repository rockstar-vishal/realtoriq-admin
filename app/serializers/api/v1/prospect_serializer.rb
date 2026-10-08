# frozen_string_literal: true

module Api
  module V1
    # The list card does not include the phone number. Call and Edit load
    # one number from GET /prospects/:id/mobile. Home never receives a
    # prospect row, only counts.
    module ProspectSerializer
      class << self
        def card(prospect, user)
          {
            id: prospect.id,
            name: prospect.name,
            comment: prospect.comment,
            status: prospect.status,
            next_action_at: prospect.next_action_at,
            latest_note: prospect.latest_note,
            project: inventory(prospect.project, :name),
            property: inventory(prospect.property, :title),
            can_delete: prospect.manager_can_delete?(user),
            can_move_back: prospect.can_move_to_following?(user),
            created_at: prospect.created_at,
            updated_at: prospect.updated_at
          }.merge(lead_link(prospect, user))
        end

        private

        def inventory(record, label)
          return if record.nil?

          { id: record.id, label => record.public_send(label), code: record.code }
        end

        def lead_link(prospect, user)
          lead = prospect.lead
          return { lead_code: nil, lead_accessible: false } if lead.nil?

          accessible = user.super_admin? || user.manager? || lead.assigned_user_id == user.id
          payload = { lead_code: lead.code, lead_accessible: accessible }
          payload[:lead_id] = lead.id if accessible
          payload
        end
      end
    end
  end
end
