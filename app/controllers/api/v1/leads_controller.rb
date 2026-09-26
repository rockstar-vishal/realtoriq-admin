# frozen_string_literal: true

module Api
  module V1
    class LeadsController < AuthenticatedController
      before_action :set_lead, only: %i[show update status matches]

      SORTS = {
        "ncd" => :as_ncd,
        "worklist" => :as_worklist,
        "recent" => -> { order(created_at: :desc) },
        "updated" => -> { order(updated_at: :desc) }
      }.freeze
      DEFAULT_SORT = "ncd"

      # Drawer fields. Heading-card params (`status`, `visited`,
      # `missed_followup`) are not in this list — they must not drop `q`, or
      # My Leads search-plus-New would break.
      DRAWER_KEYS = %w[
        name mobile email ncd_from ncd_upto budget_min budget_max
        typology_ids transaction_type property_type_id possession_from possession_to
        source_id assigned_user_id
      ].freeze

      def index
        leads = filtered_scope
        @pagy, records = pagy(leads, limit: per_page)
        Lead.preload_card_extras(records)

        render json: {
          leads: records.map { |lead| LeadSerializer.list(lead) },
          counts: card_counts,
          meta: pagination_meta(@pagy)
        }, status: :ok
      end

      def show
        render json: { lead: detail_payload(@lead) }, status: :ok
      end

      def create
        result = ::Leads::Create.new(
          firm: current_firm, actor: current_user,
          attributes: lead_params, typology_ids: params[:typology_ids],
          copy_project_typologies: !params.key?(:typology_ids),
          project_id: params[:project_id],
          followup: followup_params
        ).call

        unless result.ok?
          if result.error_code
            return render_error(result.error_code, result.error_message,
                                status: :unprocessable_content, details: result.error_details)
          end

          return render_validation_errors(result.errors)
        end

        lead = result.lead

        render json: {
          lead: detail_payload(lead),
          # The other transaction type on this number, if any — same type is
          # refused with duplicate_lead. Visibility-filtered so an agent does
          # not learn about a lead they cannot open.
          possible_duplicates: Lead.preload_card_extras(
            lead.possible_duplicates.visible_to(current_user).limit(5)
          ).map { |d| LeadSerializer.list(d) }
        }, status: :created
      end

      def update
        saved = false
        assignment_error = nil

        # The whole update in one transaction. `replace_typologies` deletes the
        # join rows immediately, so before this a rejected save left the lead
        # with its preferred configurations already gone — a 422 that silently
        # destroyed data the caller never asked to change.
        @lead.transaction do
          assignment_error = apply_assignment
          raise ActiveRecord::Rollback if assignment_error

          @lead.assign_attributes(update_params)
          apply_budget_write
          replace_typologies if params.key?(:typology_ids)
          saved = @lead.save
          raise ActiveRecord::Rollback unless saved

          record_reassignment_audit if @assignment_changed
        end

        return render_assignment_error(assignment_error) if assignment_error
        return render_lead_save_failure(@lead) unless saved

        render json: { lead: detail_payload(@lead.reload) }, status: :ok
      end

      # LaunchIQ is not wired yet. Same shape the live feed will use, so the
      # app can ship the empty state against a real endpoint.
      def matches
        render json: { matches: [] }, status: :ok
      end

      def status
        result = ::Leads::TransitionStatus.new(
          lead: @lead,
          to_status: LeadStatus.find_by(code: params.require(:status)),
          actor: current_user,
          reason: params[:reason],
          note: params[:note]
        ).call

        unless result.ok?
          return render_error(result.error_code, result.error_message, status: :unprocessable_content)
        end

        render json: { lead: detail_payload(@lead.reload) }, status: :ok
      end

      private

      # Superadmin: any active user in the firm. Anyone else: active manageables
      # (always includes themselves). `null` unassigns and is manager-role+ only
      # — an agent unassigning would hide the lead from every agent, including
      # themselves.
      def apply_assignment
        return unless params.key?(:assigned_user_id)

        raw = params[:assigned_user_id]
        if raw.blank?
          unless current_user.super_admin? || current_user.manager?
            return { code: "forbidden_role", message: "Only a manager can unassign a lead.",
                     status: :forbidden }
          end

          @assignment_changed = @lead.assigned_user_id.present?
          @lead.assigned_user = nil
          return
        end

        assignee = User.assignable_scope_for(current_user).find_by(id: raw)
        if assignee.nil?
          return { code: "unknown_user", message: "That user isn't in this firm.", status: :not_found }
        end

        @assignment_changed = @lead.assigned_user_id != assignee.id
        @lead.assigned_user = assignee
        nil
      end

      def render_assignment_error(error)
        render_error(error[:code], error[:message], status: error[:status])
      end

      def render_lead_save_failure(lead)
        existing = lead.duplicate_on_mobile_and_type
        if existing
          return render_error(
            "duplicate_lead",
            "A #{lead.transaction_type} lead already exists for this number.",
            status: :unprocessable_content,
            details: { lead_id: existing.id, transaction_type: lead.transaction_type }
          )
        end

        render_validation_errors(lead.errors)
      end

      def record_reassignment_audit
        AuditEvent.record!(subject: @lead, firm: current_firm, actor: current_user,
                           action: "lead.reassigned",
                           metadata: { to: @lead.assigned_user_id })
      end

      # Scoped twice on purpose: FirmScoped keeps other tenants out, visible_to
      # keeps other agents' pipelines out.
      def visible_leads
        Lead.visible_to(current_user)
      end

      def set_lead
        @lead = visible_leads.find_by(id: params[:id])
        return if @lead

        # Not found rather than forbidden, for another firm's lead *and* another
        # agent's: a 403 would confirm the record exists.
        render_error("not_found", "Lead not found", status: :not_found)
      end

      def filtered_scope
        scope = visible_leads
          .includes(:lead_status, :property_type, :lead_source, :assigned_user, :typologies)
          .search(drawer_filters_present? ? nil : params[:q])
          .named_like(params[:name])
          .mobile_like(params[:mobile])
          .email_like(params[:email])
          .ncd_between(params[:ncd_from], params[:ncd_upto])
          .with_status(params[:status])
          .with_visited(params[:visited])
          .with_missed_followup(params[:missed_followup])
          .budget_between(params[:budget_min], params[:budget_max])
          .possession_between(params[:possession_from], params[:possession_to])
          .for_typologies(params[:typology_ids])

        scope = scope.where(transaction_type: params[:transaction_type]) if params[:transaction_type].present?
        scope = scope.where(property_type_id: params[:property_type_id]) if params[:property_type_id].present?
        scope = scope.where(lead_source_id: params[:source_id]) if params[:source_id].present?
        # Agents are already narrowed to themselves; for them this can only
        # filter further, never widen.
        scope = scope.where(assigned_user_id: params[:assigned_user_id]) if params[:assigned_user_id].present?

        apply_sort(scope)
      end

      def drawer_filters_present?
        DRAWER_KEYS.any? { |key| params[key].present? }
      end

      def apply_sort(scope)
        sort = SORTS.fetch(params[:sort].to_s, SORTS[DEFAULT_SORT])
        sort.is_a?(Symbol) ? scope.public_send(sort) : scope.instance_exec(&sort)
      end

      # Pipeline totals for the six cards, visibility-scoped and independent of
      # the current list filter. Cards overlap (New + overdue is both New and
      # Missed), so these will not sum to meta.total_count.
      def card_counts
        now = Time.current
        sql = <<~SQL.squish
          COUNT(*) FILTER (WHERE lead_statuses.code = 'new'),
          COUNT(*) FILTER (WHERE leads.next_action_at <= :now AND lead_statuses.is_terminal = FALSE),
          COUNT(*) FILTER (WHERE lead_statuses.code = 'visit_planned'),
          COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM lead_visits WHERE lead_visits.lead_id = leads.id)),
          COUNT(*) FILTER (WHERE lead_statuses.code IN ('hot', 'negotiation')),
          COUNT(*) FILTER (WHERE lead_statuses.code = 'booked')
        SQL
        row = visible_leads.joins(:lead_status).pick(
          Arel.sql(Lead.sanitize_sql_array([ sql, { now: } ]))
        )
        new_count, missed, visit_planned, visited, hot_negotiation, booked = Array(row)

        {
          new: new_count.to_i,
          missed_followup: missed.to_i,
          visit_planned: visit_planned.to_i,
          visited: visited.to_i,
          hot_negotiation: hot_negotiation.to_i,
          booked: booked.to_i
        }
      end

      def apply_budget_write
        return unless params.key?(:budget)

        @lead.budget_min = nil
        @lead.budget_max = params[:budget].presence
      end

      def detail_payload(lead) = LeadSerializer.full_detail(lead)

      def replace_typologies
        @lead.lead_typologies.destroy_all
        Array(params[:typology_ids]).compact_blank.each do |id|
          @lead.lead_typologies.build(typology_id: id)
        end
      end

      def render_validation_errors(errors)
        render_error("invalid", errors.full_messages.to_sentence,
                     status: :unprocessable_content, details: errors.to_hash)
      end

      def per_page
        requested = params[:per_page].to_i
        # An absent param is 0, and clamping that would silently page by one.
        return 25 if requested <= 0

        requested.clamp(1, 50)
      end

      # Create may set an owner — an agent's own lead is auto-assigned to them,
      # and a manager can assign at creation.
      def lead_params
        params.permit(
          :name, :mobile, :alt_mobile, :email, :transaction_type, :property_type_id,
          :budget, :possession_by, :lead_source_id, :source_detail,
          :assigned_user_id, :notes
        )
      end

      def followup_params
        raw = params[:followup]
        return if raw.blank?
        return unless raw.respond_to?(:permit)

        raw.permit(:comment, :next_action_at)
      end
      # project_id is create-only (copy + map). It is not a lead column.
      # `budget` is the single stored amount (written to budget_max). Query
      # budget_min / budget_max on GET are a filter window, not write fields.

      # Reassignment is applied in #apply_assignment, which checks the
      # assignable pool — not via assign_attributes, which used to write the
      # column with neither a role check nor a firm check.
      # `budget` is not a column; #apply_budget_write maps it onto budget_max.
      def update_params = lead_params.except(:assigned_user_id, :budget)
    end
  end
end
