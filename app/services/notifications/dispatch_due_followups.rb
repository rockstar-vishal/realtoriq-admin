# frozen_string_literal: true

module Notifications
  # Notifies the assignee when a lead's follow-up time has just come due.
  #
  # The first run only plants a watermark at now, so the overdue backlog is
  # not pushed in a burst. Later runs catch up everything that became due
  # after that watermark, including time the worker was down.
  #
  # Runnable from a console in any environment:
  #   Notifications::DispatchDueFollowups.call
  class DispatchDueFollowups
    KEY = "followup_due"
    Result = Struct.new(:ok?, :dispatched, :initialized, keyword_init: true)

    def self.call
      new.call
    end

    def call
      now = Time.current
      watermark = claim_watermark(now)
      return Result.new(ok?: true, dispatched: 0, initialized: true) if watermark.nil?

      leads = due_leads(watermark, now)
      dispatched = leads.count { |lead| notify(lead) }
      advance_watermark(watermark, now)
      Result.new(ok?: true, dispatched:, initialized: false)
    end

    # nil means this was the first run and the backlog was not sent.
    def claim_watermark(now)
      NotificationDispatchState.transaction do
        state = NotificationDispatchState.find_or_create_by!(key: KEY)
        state.lock!
        if state.last_dispatched_at.nil?
          state.update!(last_dispatched_at: now)
          nil
        else
          state.last_dispatched_at
        end
      end
    end

    # Only move forward. A crash before this leaves the old watermark, so the
    # next run retries; the dedupe key stops a second push.
    def advance_watermark(_watermark, now)
      NotificationDispatchState.transaction do
        state = NotificationDispatchState.lock.find_by!(key: KEY)
        state.update!(last_dispatched_at: now) if state.last_dispatched_at < now
      end
    end

    private

    def due_leads(watermark, now)
      Lead.across_firms
        .where.not(assigned_user_id: nil)
        .where("leads.next_action_at > ? AND leads.next_action_at <= ?", watermark, now)
        .joins(:lead_status)
        .where(lead_statuses: { is_terminal: false })
        .includes(:assigned_user, :firm, :lead_status)
        .to_a
    end

    def notify(lead)
      user = lead.assigned_user
      return false if user.nil? || user.disabled?

      result = Current.set(firm: lead.firm, user:) do
        Record.call(
          user:,
          kind: "followup_due",
          title: title_for(lead),
          body: body_for(lead),
          dedupe_key: dedupe_key(lead),
          data: { "page" => "leads", "item" => lead.id }
        )
      end
      result.created
    end

    # A visit planned with a time makes this call the reminder before the
    # visit. A visit planned before that time was stored keeps the plain text.
    def reminder_call?(lead)
      lead.lead_status&.code == "visit_planned" &&
        lead.visit_planned_at.present? &&
        lead.next_action_at.present? &&
        lead.next_action_at < lead.visit_planned_at
    end

    def title_for(lead)
      name = lead.display_name
      reminder_call?(lead) ? "Reminder Call — #{name}" : "Followup — #{name}"
    end

    def body_for(lead)
      reminder_call?(lead) ? visit_body(lead) : due_body(lead)
    end

    def due_body(lead)
      stamp = lead.next_action_at.in_time_zone("Asia/Kolkata")
      "Due #{stamp.strftime('%-d %b, %-I:%M %p')}"
    end

    def visit_body(lead)
      stamp = lead.visit_planned_at.in_time_zone("Asia/Kolkata")
      "Site Visit #{stamp.strftime('%a %-d %b, %-I:%M %p')}"
    end

    def dedupe_key(lead)
      "followup_due:#{lead.id}:#{lead.next_action_at.iso8601(6)}"
    end
  end
end
