# frozen_string_literal: true

module Api
  module V1
    class ProspectFollowupsController < AuthenticatedController
      before_action :set_prospect

      def create
        result = ::Prospects::RecordFollowup.new(
          prospect: @prospect, actor: current_user, connected: connected_param,
          notes: params[:notes], next_action_at: params[:next_action_at],
          mark_not_interested: params[:mark_not_interested], disposition: params[:disposition],
          lead: lead_param
        ).call
        return render_service_error(result) unless result.ok?

        render json: {
          prospect: ProspectSerializer.card(reload_prospect(result.prospect), current_user),
          followup: followup_json(result.followup)
        }, status: :created
      end

      private

      def set_prospect
        @prospect = Prospect.find(params[:prospect_id])
      end

      # Missing and the string "false" must not both become false. A missing
      # answer is nil so the service can ask for it.
      def connected_param
        return if !params.key?(:connected) || params[:connected].nil?

        ActiveModel::Type::Boolean.new.cast(params[:connected])
      end

      def lead_param
        raw = params[:lead]
        return if raw.blank?

        raw.permit(:mode, :project_id, :property_id, :transaction_type, :property_type_id, :budget,
          typology_ids: [], locality_ids: [])
      end

      def followup_json(followup)
        return if followup.nil?

        {
          id: followup.id,
          connected: followup.connected,
          notes: followup.notes,
          outcome: followup.outcome,
          next_action_at: followup.next_action_at,
          created_at: followup.created_at
        }
      end

      def render_service_error(result)
        status = result.error_code == "forbidden_role" ? :forbidden : :unprocessable_content
        render_error(result.error_code, result.error_message, status:, details: result.error_details)
      end

      def reload_prospect(prospect)
        record = Prospect.includes(:project, :property, :lead).find(prospect.id)
        Prospect.preload_latest_notes([ record ])
        record
      end
    end
  end
end
