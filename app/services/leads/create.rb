# frozen_string_literal: true

module Leads
  # Creating a lead writes three things: the lead, its typology selections, and
  # the opening row of its status history — so the dead-leads report can see
  # when a lead entered the pipeline, not only when it left.
  class Create
    class FollowupFailed < StandardError
      attr_reader :result

      def initialize(result)
        @result = result
        super(result.error_message)
      end
    end

    Result = Struct.new(:ok?, :lead, :errors, :error_code, :error_message, :error_details,
                        keyword_init: true)

    MAX_CODE_ATTEMPTS = 5
    DUPLICATE_INDEX = "index_leads_on_firm_mobile_transaction_type"

    def initialize(firm:, actor:, attributes:, typology_ids: [],
                   copy_project_typologies: false, project_id: nil, followup: nil)
      @firm = firm
      @actor = actor
      @attributes = attributes
      @typology_ids = Array(typology_ids).compact_blank
      @copy_project_typologies = copy_project_typologies
      @project_id = project_id.presence
      @followup_attrs = followup
    end

    def call
      status = default_status
      return failure_without_statuses if status.nil?

      lead = build(status)
      apply_project_defaults(lead)
      return duplicate_result(lead) if lead.duplicate_on_mobile_and_type

      attempts = 0

      begin
        Lead.transaction do
          lead.save!
          assign_typologies(lead)
          map_source_project(lead)
          open_status_history(lead)
          record_opening_followup(lead)
        end
      rescue FollowupFailed => e
        return Result.new(ok?: false, lead:, error_code: e.result.error_code,
                          error_message: e.result.error_message, errors: e.result.errors)
      rescue ActiveRecord::RecordNotUnique => e
        return duplicate_result(lead) if e.message.include?(DUPLICATE_INDEX)

        attempts += 1
        raise if attempts >= MAX_CODE_ATTEMPTS

        # Clear it so assign_code computes the next number — otherwise the retry
        # re-submits the code that just collided, forever.
        lead.code = nil
        retry
      end

      Result.new(ok?: true, lead:)
    rescue ActiveRecord::RecordInvalid => e
      record = e.record
      return duplicate_result(record) if record.respond_to?(:duplicate_on_mobile_and_type) &&
        record.duplicate_on_mobile_and_type

      Result.new(ok?: false, lead: record, errors: record.errors)
    end

    private

    attr_reader :firm, :actor, :attributes, :typology_ids, :copy_project_typologies, :project_id,
      :followup_attrs

    # `budget` is not a column — it is written to budget_max with min cleared.
    # budget_min on the payload is ignored so a leftover range cannot be stored.
    # NCD and follow-up comments are not lead columns on write; they go through
    # RecordFollowup so a client cannot overwrite the log or the current NCD.
    def non_column_keys
      [
        :assigned_user_id, "assigned_user_id", :budget, "budget", :budget_min, "budget_min",
        :next_action_at, "next_action_at", :next_action_note, "next_action_note",
        :followup, "followup", :emi, "emi"
      ]
    end

    def build(status)
      lead = Lead.new(attributes.except(*non_column_keys))
      lead.firm = firm
      lead.lead_status ||= status
      apply_single_budget(lead)

      assign_owner(lead)
      lead
    end

    def apply_single_budget(lead)
      return unless attributes.key?(:budget) || attributes.key?("budget")

      lead.budget_min = nil
      lead.budget_max = attributes[:budget] || attributes["budget"]
    end

    # Create may set an owner. Superadmin: any active user in the firm. Anyone
    # else: active manageables. An agent with no assignee of their own is
    # assigned to themselves, or the lead would vanish from their worklist.
    def assign_owner(lead)
      requested_id = attributes[:assigned_user_id].presence || attributes["assigned_user_id"].presence
      if requested_id
        assignee = User.assignable_scope_for(actor).find_by(id: requested_id)
        if assignee.nil?
          lead.errors.add(:assigned_user_id, "isn't assignable")
          raise ActiveRecord::RecordInvalid, lead
        end
        lead.assigned_user = assignee
      elsif actor.agent?
        lead.assigned_user_id = actor.id
      end
    end

    def source_project
      return @source_project if defined?(@source_project)

      @source_project = project_id.present? ? Project.find_by(id: project_id) : nil
    end

    # Copy only fields the project actually has, and only into blanks — the
    # form wins when the broker filled something in.
    def apply_project_defaults(lead)
      return if project_id.blank?

      if source_project.nil?
        lead.errors.add(:project_id, "isn't one of this firm's records")
        raise ActiveRecord::RecordInvalid, lead
      end

      if lead.budget_min.blank? && lead.budget_max.blank? && source_project.starting_budget.present?
        lead.budget_max = source_project.starting_budget
      end
      lead.possession_by ||= source_project.possession_on
      return if lead.notes.present?

      lines = [ "Client's requirements" ]
      location = [ source_project.locality&.name, source_project.city&.name ].compact_blank.join(", ")
      lines << "Location: #{location}" if location.present?
      lead.notes = lines.join("\n")
    end

    def default_status = LeadStatus.active.ordered.first

    def failure_without_statuses
      lead = Lead.new
      lead.errors.add(:base, "No lead statuses are configured — run bin/rails db:seed")
      Result.new(ok?: false, lead:, errors: lead.errors)
    end

    def assign_typologies(lead)
      ids = typology_ids
      ids = source_project.typology_ids if ids.empty? && copy_project_typologies && source_project
      ids.each { |id| lead.lead_typologies.create!(typology_id: id) }
    end

    def map_source_project(lead)
      return if source_project.nil?

      lead.lead_projects.create!(project: source_project, firm:)
    end

    def duplicate_result(lead)
      existing = lead.duplicate_on_mobile_and_type
      Result.new(
        ok?: false, lead:,
        error_code: "duplicate_lead",
        error_message: "A #{lead.transaction_type} lead already exists for this number.",
        error_details: existing && { lead_id: existing.id, transaction_type: lead.transaction_type }
      )
    end

    def record_opening_followup(lead)
      raw = followup_attrs
      return if raw.blank?

      comment = raw[:comment] || raw["comment"]
      ncd = raw[:next_action_at] || raw["next_action_at"]
      return if comment.blank? && ncd.blank?

      result = RecordFollowup.new(
        lead:, actor:, comment:, next_action_at: ncd
      ).call
      return if result.ok?

      raise FollowupFailed, result
    end

    def open_status_history(lead)
      lead.lead_status_changes.create!(
        firm:, from_status: nil, to_status: lead.lead_status,
        user: actor, changed_at: Time.current
      )
    end
  end
end
