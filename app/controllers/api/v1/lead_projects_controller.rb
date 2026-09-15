# frozen_string_literal: true

module Api
  module V1
    # Join rows between a lead and a project it is considering. Flat controller
    # name so it does not shadow the Inventory:: / Leads:: service namespaces.
    class LeadProjectsController < AuthenticatedController
      before_action :set_lead

      def create
        mapping = @lead.lead_projects.build(project_id: params[:project_id], firm: current_firm)

        unless mapping.save
          return render_error("invalid", mapping.errors.full_messages.to_sentence,
                              status: :unprocessable_content, details: mapping.errors.to_hash)
        end

        render json: { lead: lead_detail }, status: :created
      rescue ActiveRecord::RecordNotUnique
        render_error("invalid", "That project is already mapped to this lead.",
                     status: :unprocessable_content)
      end

      def destroy
        mapping = @lead.lead_projects.find_by(id: params[:id])
        if mapping.nil?
          return render_error("not_found", "Mapping not found", status: :not_found)
        end

        mapping.destroy!
        render json: { lead: lead_detail }, status: :ok
      end

      private

      def set_lead
        @lead = Lead.visible_to(current_user).find_by(id: params[:lead_id])
        return if @lead

        render_error("not_found", "Lead not found", status: :not_found)
      end

      def lead_detail = LeadSerializer.full_detail(@lead.reload)
    end
  end
end
