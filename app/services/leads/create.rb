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

    def initialize(firm:, actor:, attributes:, typology_ids: [],
                   copy_project_typologies: false, locality_ids: [],
                   copy_project_localities: false, require_locality: true,
                   project_id: nil, followup: nil, near_place: nil, near_place_supplied: false)
      @firm = firm
      @actor = actor
      @attributes = attributes
      @typology_ids = Array(typology_ids).compact_blank
      @copy_project_typologies = copy_project_typologies
      @locality_ids = Array(locality_ids).compact_blank
      @copy_project_localities = copy_project_localities
      @require_locality = require_locality
      @project_id = project_id.presence
      @followup_attrs = followup
      @near_place = near_place
      @near_place_supplied = near_place_supplied
    end

    def call
      status = default_status
      return failure_without_statuses if status.nil?

      lead = build(status)
      apply_project_defaults(lead)
      # Category is part of the duplicate key. It has to be known before the
      # check, and before configurations are saved — a mixed project's rows
      # repeat ids, and only this category's ids may be copied.
      rejected = assign_category(lead)
      return rejected if rejected
      return duplicate_result(lead) if lead.duplicate_on_mobile_and_type

      attempts = 0

      begin
        # A savepoint, not a joined transaction. An enquiry already holds one,
        # and a unique-index collision would otherwise abort that outer
        # transaction instead of retrying here.
        Lead.transaction(requires_new: true) do
          apply_near_place(lead)
          lead.save!
          assign_typologies(lead)
          assign_localities(lead)
          ensure_match_fields!(lead)
          record_unqualified_audit(lead)
          map_source_project(lead)
          open_status_history(lead)
          record_opening_followup(lead)
        end
      rescue FollowupFailed => e
        return Result.new(ok?: false, lead:, error_code: e.result.error_code,
                          error_message: e.result.error_message, errors: e.result.errors)
      rescue ActiveRecord::RecordNotUnique => e
        return duplicate_result(lead) if Lead.duplicate_index_violation?(e)

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

    attr_reader :firm, :actor, :attributes, :typology_ids, :copy_project_typologies,
      :locality_ids, :copy_project_localities, :require_locality, :project_id, :followup_attrs,
      :near_place, :near_place_supplied

    # `budget` is not a column — it is written to budget_max with min cleared.
    # budget_min on the payload is ignored so a leftover range cannot be stored.
    # NCD and follow-up comments are not lead columns on write; they go through
    # RecordFollowup so a client cannot overwrite the log or the current NCD.
    def apply_near_place(lead)
      return unless near_place_supplied

      if near_place.nil?
        lead.assign_attributes(
          near_label: nil, near_address: nil, near_lat: nil, near_lng: nil, near_place_id: nil
        )
        return
      end

      lead.near_label = near_place[:label]
      lead.near_address = near_place[:address]
      lead.near_lat = near_place[:lat]
      lead.near_lng = near_place[:lng]
      lead.near_place_id = near_place[:google_place_id]
    end

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

      @source_project = if project_id.blank?
        nil
      else
        Project.find_by(id: project_id) || Project.marketplace.find_by(id: project_id)
      end
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

    def assign_category(lead)
      if typology_ids.present?
        categories = Typology.where(id: typology_ids).distinct.pluck(:category)
        return category_rejected if categories.many?

        if categories.one?
          return category_rejected if requested_category && requested_category != categories.first

          lead.category = categories.first
        end
      elsif copy_project_typologies && source_project
        lead.category = requested_category || source_project.primary_category || lead.category
      end
      nil
    end

    def requested_category
      value = attributes[:category] || attributes["category"]
      value.to_s.presence
    end

    def category_rejected
      lead = Lead.new
      lead.errors.add(:base, "Pick configurations from one category.")
      Result.new(
        ok?: false, lead:, errors: lead.errors,
        error_code: "invalid",
        error_message: "Pick configurations from one category."
      )
    end

    def assign_typologies(lead)
      ids = typology_ids
      if ids.empty? && copy_project_typologies && source_project
        ids = source_project.typology_ids_for(lead.category)
      end
      ids.uniq.each { |id| lead.lead_typologies.create!(typology_id: id) }
    end

    def assign_localities(lead)
      ids = locality_ids
      if ids.empty? && copy_project_localities && source_project&.locality_id
        ids = [ source_project.locality_id ]
      end
      # Ids that no longer exist (an app holding a cached list from before localities
      # were merged) are dropped; the require-locality check below still applies.
      Locality.where(id: ids.uniq).pluck(:id).each { |id| lead.lead_localities.create!(locality_id: id) }
    end

    # The column default is false, and a create always looks like a change from
    # nil. Audit only when the caller actually marked the lead unqualified.
    def record_unqualified_audit(lead)
      return unless lead.unqualified?

      AuditEvent.record!(
        subject: lead, firm:, actor:,
        action: "lead.unqualified",
        metadata: { unqualified: true }
      )
    end

    # A broker create must have a budget, a configuration and a locality.
    # A microsite enquiry may omit locality when the project has none. Budget
    # and configuration still have to be there — the project copy supplies them.
    def ensure_match_fields!(lead)
      lead.errors.add(:budget, "is required") if lead.budget_amount.blank?
      lead.errors.add(:typology_ids, "must include a configuration") if lead.lead_typologies.empty?
      if require_locality && lead.lead_localities.empty?
        lead.errors.add(:locality_ids, "must include a locality")
      end
      raise ActiveRecord::RecordInvalid, lead if lead.errors.any?
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
        error_message: lead.open_duplicate_message,
        error_details: lead.open_duplicate_details(existing)
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
