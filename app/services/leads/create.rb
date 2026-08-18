# frozen_string_literal: true

module Leads
  # Creating a lead writes three things: the lead, its typology selections, and
  # the opening row of its status history — so the dead-leads report can see
  # when a lead entered the pipeline, not only when it left.
  class Create
    Result = Struct.new(:ok?, :lead, :errors, keyword_init: true)

    MAX_CODE_ATTEMPTS = 5

    def initialize(firm:, actor:, attributes:, typology_ids: [])
      @firm = firm
      @actor = actor
      @attributes = attributes
      @typology_ids = Array(typology_ids).compact_blank
    end

    def call
      status = default_status
      return failure_without_statuses if status.nil?

      lead = build(status)
      attempts = 0

      begin
        Lead.transaction do
          lead.save!
          assign_typologies(lead)
          open_status_history(lead)
        end
      rescue ActiveRecord::RecordNotUnique
        attempts += 1
        raise if attempts >= MAX_CODE_ATTEMPTS

        # Clear it so assign_code computes the next number — otherwise the retry
        # re-submits the code that just collided, forever.
        lead.code = nil
        retry
      end

      Result.new(ok?: true, lead:)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok?: false, lead: e.record, errors: e.record.errors)
    end

    private

    attr_reader :firm, :actor, :attributes, :typology_ids

    def build(status)
      lead = Lead.new(attributes)
      lead.firm = firm
      lead.lead_status ||= status

      # An agent sees only leads assigned to them, so one they create unassigned
      # would vanish the moment it saved. Managers may leave it unassigned.
      lead.assigned_user_id ||= actor.id if actor.agent?

      lead
    end

    def default_status = LeadStatus.active.ordered.first

    def failure_without_statuses
      lead = Lead.new
      lead.errors.add(:base, "No lead statuses are configured — run bin/rails db:seed")
      Result.new(ok?: false, lead:, errors: lead.errors)
    end

    def assign_typologies(lead)
      typology_ids.each { |id| lead.lead_typologies.create!(typology_id: id) }
    end

    def open_status_history(lead)
      lead.lead_status_changes.create!(
        firm:, from_status: nil, to_status: lead.lead_status,
        user: actor, changed_at: Time.current
      )
    end
  end
end
