# frozen_string_literal: true

module Leads
  # The only write path for follow-up comments and for moving a lead's NCD.
  # Status change is optional and goes through TransitionStatus in the same
  # transaction so a failed dead-reason cannot leave a dangling followup.
  class RecordFollowup
    Result = Struct.new(:ok?, :followup, :lead, :error_code, :error_message, :errors,
                        keyword_init: true)

    class StatusFailed < StandardError
      attr_reader :result

      def initialize(result)
        @result = result
        super(result.error_message)
      end
    end

    def initialize(lead:, actor:, comment:, next_action_at: nil, status: nil,
                   reason: nil, booked_on: nil)
      @lead = lead
      @actor = actor
      @comment = comment.to_s.strip
      @next_action_at = next_action_at
      @status_code = status.to_s.strip.presence
      @reason = reason
      @booked_on = booked_on
    end

    def call
      return failure("comment_required", "What was discussed with the client is required.") if comment.blank?

      to_status = resolve_status
      return failure("unknown_status", "That status doesn't exist.") if status_code && to_status.nil?

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
        locked = Lead.lock.find(lead.id)
        followup = locked.lead_followups.create!(
          firm: locked.firm, user: actor, comment:, next_action_at: parsed_ncd
        )
        locked.update!(next_action_at: parsed_ncd) if parsed_ncd

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
                 error_message: e.result.error_message)
    end

    private

    attr_reader :lead, :actor, :comment, :next_action_at, :status_code, :reason, :booked_on

    def resolve_status
      return if status_code.blank?

      LeadStatus.find_by(code: status_code)
    end

    def booking_change?(to_status)
      to_status.present? && to_status.is_booked? && to_status.id != lead.lead_status_id
    end

    def parsed_ncd
      return @parsed_ncd if defined?(@parsed_ncd)

      raw = next_action_at.presence
      @parsed_ncd = raw ? Time.zone.parse(raw.to_s) : nil
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
