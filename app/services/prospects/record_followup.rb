# frozen_string_literal: true

module Prospects
  # The call log on the prospect list. Interested is saved together with the
  # lead; anything else only moves the prospect. A closed prospect (interested
  # or not interested) cannot take another follow-up.
  class RecordFollowup
    Result = Struct.new(:ok?, :prospect, :followup, :error_code, :error_message, :error_details,
      keyword_init: true)

    def initialize(prospect:, actor:, connected:, notes:, next_action_at: nil,
      mark_not_interested: false, disposition: nil, lead: nil)
      @prospect = prospect
      @actor = actor
      @connected = connected
      @notes = notes.to_s.strip
      @next_action_at = next_action_at
      @mark_not_interested = ActiveModel::Type::Boolean.new.cast(mark_not_interested)
      @disposition = disposition.to_s.presence
      @lead = lead
    end

    def call
      result = nil
      Prospect.transaction do
        result = write
        raise ActiveRecord::Rollback unless result.ok?
      end
      result
    end

    private

    attr_reader :prospect, :actor, :connected, :notes, :next_action_at, :mark_not_interested,
      :disposition, :lead

    def write
      return failure("notes_required", "Add a note about the call.") if notes.blank?
      return failure("connected_required", "Say whether the call connected.") if connected.nil?

      locked = Prospect.lock.find(prospect.id)
      if locked.status_interested? || locked.status_not_interested?
        return failure("prospect_closed", "This prospect is not open for a follow-up.")
      end

      connected ? record_connected(locked) : record_missed(locked)
    end

    def record_missed(locked)
      if mark_not_interested
        followup = save_followup(locked, connected: false, outcome: "not_interested", ncd: nil)
        locked.update!(status: "not_interested", next_action_at: nil)
        return Result.new(ok?: true, prospect: locked, followup:)
      end

      parsed = parsed_ncd
      return parsed if parsed.is_a?(Result)

      followup = save_followup(locked, connected: false, outcome: "retry", ncd: parsed)
      locked.update!(status: "following", next_action_at: parsed)
      Result.new(ok?: true, prospect: locked, followup:)
    end

    def record_connected(locked)
      case disposition
      when "interested"
        convert(locked)
      when "not_interested"
        followup = save_followup(locked, connected: true, outcome: "not_interested", ncd: nil)
        locked.update!(status: "not_interested", next_action_at: nil)
        Result.new(ok?: true, prospect: locked, followup:)
      when "not_sure"
        followup = save_followup(locked, connected: true, outcome: "not_sure", ncd: nil)
        locked.update!(status: "following") unless locked.status_following?
        Result.new(ok?: true, prospect: locked, followup:)
      else
        failure("invalid", "Choose whether the client was interested.")
      end
    end

    def convert(locked)
      converted = Convert.new(prospect: locked, actor:, notes:, lead:).call
      return converted if converted.ok?

      Result.new(ok?: false, prospect: locked, error_code: converted.error_code,
        error_message: converted.error_message, error_details: converted.error_details)
    end

    def save_followup(locked, connected:, outcome:, ncd:)
      locked.prospect_followups.create!(
        firm: locked.firm, user: actor, connected:, notes:, outcome:, next_action_at: ncd
      )
    end

    def parsed_ncd
      raw = next_action_at.to_s.strip
      return failure("ncd_required", "Say when you will dial next.") if raw.blank?

      parsed = Time.zone.parse(raw)
      return failure("invalid", "Enter a date and time for the next call.") if parsed.nil?

      parsed
    end

    def failure(code, message)
      Result.new(ok?: false, prospect:, error_code: code, error_message: message)
    end
  end
end
