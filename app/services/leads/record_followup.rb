# frozen_string_literal: true

module Leads
  # The only write path for follow-up comments and for moving a lead's NCD.
  # Status change is optional and goes through TransitionStatus in the same
  # transaction so a failed dead-reason cannot leave a dangling followup.
  #
  # The broker form (POST /leads/:id/followups, and the new-lead form's first
  # followup) asks for a future next call. A note written by an enquiry or an
  # import does not: those callers leave require_next_call off, and an import
  # also leaves reject_past_next_call off.
  class RecordFollowup
    Result = Struct.new(:ok?, :followup, :lead, :error_code, :error_message, :error_details, :errors,
                        keyword_init: true)

    class StatusFailed < StandardError
      attr_reader :result

      def initialize(result)
        @result = result
        super(result.error_message)
      end
    end

    NEXT_CALL_GRACE = 2.minutes

    def initialize(lead:, actor:, comment:, next_action_at: nil, status: nil,
                   reason: nil, booked_on: nil, visit_at: nil, visit_at_supplied: false,
                   require_next_call: false, reject_past_next_call: false)
      @lead = lead
      @actor = actor
      @comment = comment.to_s.strip
      @next_action_at = next_action_at
      @status_code = status.to_s.strip.presence
      @reason = reason
      @booked_on = booked_on
      @visit_at = visit_at
      @visit_at_supplied = visit_at_supplied
      @require_next_call = require_next_call
      @reject_past_next_call = reject_past_next_call
    end

    def call
      rejection = validate_request
      return rejection if rejection

      to_status = resolve_status
      booked_at = nil
      if booking_change?(to_status)
        booked_at = parse_application_date
        if booked_at.nil?
          return failure("application_date_required", "Marking a lead booked needs an application date.")
        end
      end

      followup = nil
      locked = nil

      Lead.transaction do
        locked = lead.lock_for_activity!
        followup = locked.lead_followups.create!(
          firm: locked.firm, user: actor, comment:, next_action_at: parsed_ncd
        )
        changes = {}
        changes[:next_action_at] = parsed_ncd if parsed_ncd
        changes[:visit_planned_at] = parsed_visit if will_be_visit_planned?(to_status) && parsed_visit
        locked.update!(changes) if changes.any?

        if to_status
          result = TransitionStatus.new(
            lead: locked, to_status:, actor:, reason:, booked_at:
          ).call
          raise StatusFailed, result unless result.ok?
        end
      end

      Result.new(ok?: true, followup:, lead: locked.reload)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok?: false, errors: e.record.errors, error_code: "invalid",
                 error_message: e.record.errors.full_messages.to_sentence)
    rescue StatusFailed => e
      Result.new(ok?: false, lead:, error_code: e.result.error_code,
                 error_message: e.result.error_message, error_details: e.result.error_details)
    end

    private

    attr_reader :lead, :actor, :comment, :next_action_at, :status_code, :reason, :booked_on,
      :visit_at, :visit_at_supplied, :require_next_call, :reject_past_next_call

    # The broker form, in order. A failure here writes nothing.
    def validate_request
      return failure("comment_required", "What was discussed with the client is required.") if comment.blank?
      return failure("new_not_allowed", "A lead can't go back to New.") if status_code == "new"

      to_status = resolve_status
      return failure("unknown_status", "That status doesn't exist.") if status_code && to_status.nil?

      resulting = to_status || lead.lead_status
      if require_next_call && parsed_ncd.nil? && !resulting&.is_terminal?
        return failure("next_call_required", "Next call is required.")
      end
      if reject_past_next_call && parsed_ncd && parsed_ncd < Time.current - NEXT_CALL_GRACE
        return failure("next_call_in_past", "The next call must be in the future.")
      end
      if visit_missing?(to_status)
        return failure("visit_at_required", "Visit date is required.")
      end
      if parsed_visit && parsed_visit <= Time.current
        return failure("visit_in_past", "The visit must be in the future.")
      end

      reminder_at = reminder_visit_time(to_status)
      if parsed_ncd && reminder_at && parsed_ncd >= reminder_at
        return failure("reminder_after_visit", "The reminder call must be before the visit.")
      end

      nil
    end

    def resolve_status
      return if status_code.blank?

      LeadStatus.find_by(code: status_code)
    end

    def visit_missing?(to_status)
      needs_one = to_status&.code == "visit_planned" ||
        (visit_at_supplied && parsed_visit.nil? && lead.lead_status&.code == "visit_planned")
      needs_one && parsed_visit.nil?
    end

    def will_be_visit_planned?(to_status)
      if status_code.present?
        to_status&.code == "visit_planned"
      else
        lead.lead_status&.code == "visit_planned"
      end
    end

    # The visit this reminder has to precede: the one just sent, or the one
    # already on the lead when this followup leaves it Visit Planned.
    def reminder_visit_time(to_status)
      return parsed_visit if parsed_visit
      return lead.visit_planned_at if will_be_visit_planned?(to_status)

      nil
    end

    def booking_change?(to_status)
      to_status.present? && to_status.is_booked? && to_status.id != lead.lead_status_id
    end

    def parsed_ncd
      return @parsed_ncd if defined?(@parsed_ncd)

      raw = next_action_at.presence
      @parsed_ncd = raw ? Time.zone.parse(raw.to_s) : nil
    rescue ArgumentError
      @parsed_ncd = nil
    end

    def parsed_visit
      return @parsed_visit if defined?(@parsed_visit)

      raw = visit_at.presence
      @parsed_visit = raw ? Time.zone.parse(raw.to_s) : nil
    rescue ArgumentError
      @parsed_visit = nil
    end

    def parse_application_date
      raw = booked_on.to_s.strip
      return if raw.blank?

      Time.find_zone(Lead::NCD_ZONE).parse(raw)&.beginning_of_day
    end

    def failure(code, message)
      Result.new(ok?: false, lead:, error_code: code, error_message: message)
    end
  end
end
