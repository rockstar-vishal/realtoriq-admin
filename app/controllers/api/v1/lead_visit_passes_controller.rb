# frozen_string_literal: true

module Api
  module V1
    class LeadVisitPassesController < AuthenticatedController
      before_action :set_lead
      before_action :set_pass, only: :refresh

      def create
        result = Realtoriq::CreateVisitPass.call(
          lead: @lead,
          user: current_user,
          project_id: params[:project_id],
          tentative_visit_planned: params[:tentative_visit_planned]
        )
        return render_pass_error(result) unless result.ok?

        render json: { visit_pass: LeadVisitPassSerializer.call(result.pass) }, status: result.status
      end

      def refresh
        result = Realtoriq::RefreshVisitPass.call(pass: @pass, actor: current_user)
        return render_pass_error(result) unless result.ok?

        render json: { visit_pass: LeadVisitPassSerializer.call(result.pass) }, status: :ok
      end

      private

      def set_lead
        @lead = Lead.visible_to(current_user).find_by(id: params[:lead_id])
        return if @lead

        render_error("not_found", "Lead not found", status: :not_found)
      end

      def set_pass
        @pass = @lead.lead_visit_passes.find_by(id: params[:id])
        return if @pass

        render_error("not_found", "Visit pass not found", status: :not_found)
      end

      def render_pass_error(result)
        render_error(result.error_code, result.error_message, status: result.status, details: result.details)
      end
    end
  end
end
