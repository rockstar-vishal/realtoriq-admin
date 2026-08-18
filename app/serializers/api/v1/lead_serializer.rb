# frozen_string_literal: true

module Api
  module V1
    # Money is emitted as raw integer rupees; the client formats lakh and crore.
    # Timestamps are ISO 8601 UTC — the firm's timezone is on /me, and rendering
    # is the client's job.
    module LeadSerializer
      class << self
        # The list card in the design: name, meta line, budget · project,
        # status, next action, visited badge.
        def list(lead)
          {
            id: lead.id,
            code: lead.code,
            name: lead.name,
            display_name: lead.display_name,
            mobile: lead.mobile,
            email: lead.email,
            transaction_type: lead.transaction_type,
            budget_min: lead.budget_min,
            budget_max: lead.budget_max,
            possession_by: lead.possession_by,
            status: status(lead.lead_status),
            property_type: named(lead.property_type),
            typologies: lead.typologies.map { |t| named(t) },
            assigned_user: named(lead.assigned_user),
            next_action_at: lead.next_action_at,
            next_action_note: lead.next_action_note,
            overdue: lead.overdue?,
            visited: lead.visited?,
            created_at: lead.created_at,
            updated_at: lead.updated_at
          }
        end

        # The lead detail screen was never designed — this is inferred from the
        # list card and the new-lead form, and should be revisited when it is.
        def detail(lead, activities: [], status_history: [])
          list(lead).merge(
            alt_mobile: lead.alt_mobile,
            source: named(lead.lead_source),
            source_detail: lead.source_detail,
            first_visit_at: lead.first_visit_at,
            dead_reason: lead.dead_reason,
            dead_at: lead.dead_at,
            booked_at: lead.booked_at,
            notes: lead.notes,
            activities: activities.map { |a| LeadActivitySerializer.call(a) },
            status_history: status_history.map { |change| history_entry(change) }
          )
        end

        private

        def status(record)
          return nil if record.nil?

          {
            id: record.id,
            code: record.code,
            name: record.name,
            color: record.color,
            is_dead: record.is_dead,
            is_booked: record.is_booked,
            is_terminal: record.is_terminal
          }
        end

        def named(record)
          return nil if record.nil?

          { id: record.id, name: record.name }
        end

        def history_entry(change)
          {
            id: change.id,
            from_status: named(change.from_status),
            to_status: named(change.to_status),
            changed_at: change.changed_at,
            user: named(change.user)
          }
        end
      end
    end
  end
end
