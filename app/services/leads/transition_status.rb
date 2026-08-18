# frozen_string_literal: true

module Leads
  # Moving a lead through the pipeline. Three writes in one transaction: the
  # lead's own column, the reporting record, and a timeline entry.
  #
  # Nothing should set lead.lead_status directly — a bare column update leaves
  # the dead-leads report unable to say when the lead died.
  class TransitionStatus
    Result = Struct.new(:ok?, :lead, :error_code, :error_message, keyword_init: true)

    def initialize(lead:, to_status:, actor:, reason: nil, note: nil)
      @lead = lead
      @to_status = to_status
      @actor = actor
      @reason = reason.to_s.strip.presence
      @note = note.to_s.strip.presence
    end

    def call
      return failure("unknown_status", "That status doesn't exist.") if to_status.nil?
      return unchanged if to_status.id == lead.lead_status_id

      # A lead marked dead without a reason is a lead nobody can learn from —
      # the dead-leads report exists precisely to answer "why".
      if to_status.is_dead? && reason.blank?
        return failure("reason_required", "Marking a lead dead needs a reason.")
      end

      from_status = lead.lead_status

      Lead.transaction do
        apply_status_columns(from_status)
        lead.save!
        record_history(from_status)
        record_activity(from_status)
      end

      Result.new(ok?: true, lead:)
    rescue ActiveRecord::RecordInvalid => e
      failure("invalid", e.record.errors.full_messages.to_sentence)
    end

    private

    attr_reader :lead, :to_status, :actor, :reason, :note

    def apply_status_columns(_from_status)
      lead.lead_status = to_status

      if to_status.is_dead?
        lead.dead_reason = reason
        lead.dead_at = Time.current
      else
        # Reviving a lead clears the death certificate, otherwise a revived
        # lead still reads as dead everywhere it is displayed.
        lead.dead_reason = nil
        lead.dead_at = nil
      end

      lead.booked_at = Time.current if to_status.is_booked?
    end

    def record_history(from_status)
      lead.lead_status_changes.create!(
        firm: lead.firm, from_status:, to_status:, user: actor, changed_at: Time.current
      )
    end

    def record_activity(from_status)
      lead.lead_activities.create!(
        firm: lead.firm,
        user: actor,
        kind: :status_change,
        body: [ "#{from_status&.name || 'New'} → #{to_status.name}", reason, note ].compact_blank.join(" · "),
        occurred_at: Time.current
      )
    end

    def unchanged = Result.new(ok?: true, lead:)

    def failure(code, message)
      Result.new(ok?: false, lead:, error_code: code, error_message: message)
    end
  end
end
