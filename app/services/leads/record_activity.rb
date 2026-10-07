# frozen_string_literal: true

module Leads
  # Logging what the broker did. Site visits are LeadVisit rows, not activities.
  class RecordActivity
    Result = Struct.new(:ok?, :activity, :errors, keyword_init: true)

    def initialize(lead:, actor:, kind:, body: nil, occurred_at: nil, outcome: nil)
      @lead = lead
      @actor = actor
      @kind = kind.to_s
      @body = body
      @occurred_at = occurred_at
      @outcome = outcome
    end

    def call
      unless LeadActivity::LOGGABLE_KINDS.include?(kind)
        return failure("kind", "must be one of #{LeadActivity::LOGGABLE_KINDS.join(', ')}")
      end

      activity = nil

      Lead.transaction do
        activity = lead.lead_activities.create!(
          firm: lead.firm, user: actor, kind:, body:, outcome:,
          occurred_at: occurred_at.presence || Time.current
        )
      end

      Result.new(ok?: true, activity:)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok?: false, errors: e.record.errors)
    end

    private

    attr_reader :lead, :actor, :kind, :body, :occurred_at, :outcome

    def failure(attribute, message)
      errors = ActiveModel::Errors.new(LeadActivity.new)
      errors.add(attribute, message)
      Result.new(ok?: false, errors:)
    end
  end
end
