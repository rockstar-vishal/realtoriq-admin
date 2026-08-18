# frozen_string_literal: true

module Leads
  # Logging what the broker did. Some activities also move the lead: a visit is
  # what makes the design's "visited" badge true, so it is derived from the
  # timeline rather than set separately, and the two cannot disagree.
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

        mark_visited(activity) if kind == "visit"
      end

      Result.new(ok?: true, activity:)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok?: false, errors: e.record.errors)
    end

    private

    attr_reader :lead, :actor, :kind, :body, :occurred_at, :outcome

    # Earliest visit wins: logging an older visit after a newer one should move
    # the first-visit date back, not leave it at whatever was recorded first.
    def mark_visited(activity)
      return if lead.first_visit_at.present? && lead.first_visit_at <= activity.occurred_at

      lead.update!(first_visit_at: activity.occurred_at)
    end

    def failure(attribute, message)
      errors = ActiveModel::Errors.new(LeadActivity.new)
      errors.add(attribute, message)
      Result.new(ok?: false, errors:)
    end
  end
end
