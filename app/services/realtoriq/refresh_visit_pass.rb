# frozen_string_literal: true

module Realtoriq
  # Pulls the latest turbo status for one pass. Refused inside six hours of
  # the previous pull. A used pass writes a follow-up comment and does not
  # change the lead's pipeline status or its next call date.
  class RefreshVisitPass
    Result = Struct.new(:ok?, :status, :error_code, :error_message, :pass, :details, keyword_init: true)

    def self.call(...)
      new(...).call
    end

    def initialize(pass:, actor:)
      @pass = pass
      @actor = actor
    end

    def call
      return too_soon unless pass.refresh_allowed?

      return failure("invalid", "This pass is not ready to refresh.") if pass.pass_code.blank?

      payload = TurboClient.fetch_visit_pass(pass.pass_code, pass.firm_id)
      before_status = pass.turbo_status
      before = snapshot(pass)
      apply(payload)
      pass.save!
      note_followup if pass.turbo_status == "used" && snapshot(pass) != before
      note_duplicate if pass.turbo_status == "duplicate" && before_status != "duplicate"
      Result.new(ok?: true, status: :ok, pass: pass.reload)
    rescue TurboClient::Error => e
      Result.new(ok?: false, status: :bad_gateway, error_code: "launchiq_rejected", error_message: e.message)
    end

    private

    attr_reader :pass, :actor

    def too_soon
      Result.new(
        ok?: false,
        status: :too_many_requests,
        error_code: "refresh_too_soon",
        error_message: "Status can be refreshed again after #{pass.next_refresh_at.in_time_zone(Lead::NCD_ZONE).strftime('%-d %b %Y, %H:%M')}.",
        pass:,
        details: { next_refresh_at: pass.next_refresh_at }
      )
    end

    def apply(payload)
      detail = payload["status_detail"].is_a?(Hash) ? payload["status_detail"] : {}
      status = payload["status"].to_s
      pass.assign_attributes(
        turbo_status: %w[unused used duplicate].include?(status) ? status : pass.turbo_status,
        status_message: payload["message"].presence,
        turbo_lead_code: payload["lead_code"].presence,
        turbo_status_name: payload["status_name"].presence,
        status_detail: detail,
        last_followup_at: parse_time(payload["last_followup_at"]),
        last_followup_comment: payload["last_followup_comment"].presence,
        next_followup_at: parse_time(payload["next_followup_at"]),
        last_fetched_at: Time.current
      )
    end

    def snapshot(record)
      [
        record.turbo_status, record.turbo_lead_code, record.turbo_status_name,
        record.status_detail, record.last_followup_comment, record.last_followup_at&.iso8601,
        record.next_followup_at&.iso8601
      ]
    end

    def note_followup
      Leads::RecordFollowup.new(lead: pass.lead, actor:, comment: comment).call
    end

    def note_duplicate
      message = pass.status_message.presence ||
        "This client is already registered with the developer. Contact your RM to get yourself tagged, subject to the builder's policy."
      Leads::RecordFollowup.new(lead: pass.lead, actor:, comment: message).call
    end

    def failure(code, message)
      Result.new(ok?: false, status: :unprocessable_content, error_code: code, error_message: message)
    end

    def comment
      parts = [ "LaunchIQ" ]
      parts << "lead #{pass.turbo_lead_code}" if pass.turbo_lead_code.present?
      parts << "status #{pass.turbo_status_name}" if pass.turbo_status_name.present?
      parts << "last note: #{pass.last_followup_comment}" if pass.last_followup_comment.present?
      if pass.next_followup_at
        parts << "next follow-up #{pass.next_followup_at.in_time_zone(Lead::NCD_ZONE).strftime('%-d %b %Y, %H:%M')}"
      end
      detail = pass.status_detail || {}
      parts << "dead reason: #{detail['dead_reason']}" if detail["dead_reason"].present?
      parts << "visit planned #{detail['tentative_visit_planned']}" if detail["tentative_visit_planned"].present?
      parts.join(". ") + "."
    end

    def parse_time(value)
      return if value.blank?

      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
