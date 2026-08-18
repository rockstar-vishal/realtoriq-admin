# frozen_string_literal: true

module Api
  module V1
    class LeadsController < AuthenticatedController
      before_action :set_lead, only: %i[show update status assign]
      before_action :require_manager, only: :assign

      SORTS = {
        "worklist" => :as_worklist,
        "recent" => -> { order(created_at: :desc) },
        "updated" => -> { order(updated_at: :desc) }
      }.freeze

      def index
        leads = filtered_scope
        @pagy, records = pagy(leads, limit: per_page)

        render json: {
          leads: records.map { |lead| LeadSerializer.list(lead) },
          meta: pagination_meta(@pagy)
        }, status: :ok
      end

      def show
        render json: { lead: detail_payload(@lead) }, status: :ok
      end

      def create
        result = ::Leads::Create.new(
          firm: current_firm, actor: current_user,
          attributes: lead_params, typology_ids: params[:typology_ids]
        ).call

        return render_validation_errors(result.errors) unless result.ok?

        lead = result.lead

        render json: {
          lead: detail_payload(lead),
          # Duplicates are allowed — the design shows several leads on one
          # number — so this informs the app rather than blocking the save.
          possible_duplicates: lead.possible_duplicates.limit(5).map { |d| LeadSerializer.list(d) }
        }, status: :created
      end

      def update
        @lead.assign_attributes(lead_params)
        replace_typologies if params.key?(:typology_ids)

        return render_validation_errors(@lead.errors) unless @lead.save

        render json: { lead: detail_payload(@lead.reload) }, status: :ok
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

      def assign
        assignee = params[:assigned_user_id].presence &&
          current_firm.users.active.find_by(id: params[:assigned_user_id])

        if params[:assigned_user_id].present? && assignee.nil?
          return render_error("unknown_user", "That user isn't in this firm.", status: :not_found)
        end

        @lead.update!(assigned_user: assignee)
        AuditEvent.record!(subject: @lead, firm: current_firm, actor: current_user,
                           action: "lead.reassigned",
                           metadata: { to: assignee&.id })

        render json: { lead: detail_payload(@lead) }, status: :ok
      end

      private

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

      def require_manager
        return if current_user.super_admin? || current_user.manager?

        render_error("forbidden_role", "Only a manager can reassign leads.", status: :forbidden)
      end

      def filtered_scope
        scope = visible_leads
          .includes(:lead_status, :property_type, :lead_source, :assigned_user, :typologies)
          .search(params[:q])
          .with_status(params[:status])
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

      def apply_sort(scope)
        sort = SORTS.fetch(params[:sort].to_s, SORTS["worklist"])
        sort.is_a?(Symbol) ? scope.public_send(sort) : scope.instance_exec(&sort)
      end

      def detail_payload(lead)
        LeadSerializer.detail(
          lead,
          activities: lead.lead_activities.includes(:user).recent_first.limit(20),
          status_history: lead.lead_status_changes.includes(:from_status, :to_status, :user).recent_first
        )
      end

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

      def lead_params
        params.permit(
          :name, :mobile, :alt_mobile, :email, :transaction_type, :property_type_id,
          :budget_min, :budget_max, :possession_by, :lead_source_id, :source_detail,
          :assigned_user_id, :next_action_at, :next_action_note, :notes
        )
      end
    end
  end
end
