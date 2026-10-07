# frozen_string_literal: true

module Api
  module V1
    # Nested under a lead. Flat controller name so Api::V1::Leads does not
    # shadow the Leads:: service namespace (same reason as activities).
    class LeadVisitsController < AuthenticatedController
      before_action :set_lead
      before_action :set_visit, only: :update

      def index
        @pagy, records = pagy(
          @lead.lead_visits.includes(:user, :projects, :properties).recent_first, limit: 25
        )

        render json: {
          visits: records.map { |visit| LeadVisitSerializer.call(visit) },
          meta: pagination_meta(@pagy)
        }, status: :ok
      end

      def create
        result = ::Leads::RecordVisit.new(
          lead: @lead, actor: current_user, attributes: write_attributes
        ).call
        render_result(result, :created)
      end

      def update
        result = ::Leads::RecordVisit.new(
          lead: @lead, actor: current_user, visit: @visit, attributes: write_attributes
        ).call
        render_result(result, :ok)
      end

      private

      def render_result(result, status)
        unless result.ok?
          return render_error(result.error_code, result.error_message,
                              status: :unprocessable_content, details: result.details)
        end

        render json: { visit: LeadVisitSerializer.call(result.visit) }, status:
      end

      # Only keys the client actually sent. An omitted site list leaves that
      # set; an empty array clears it. New ids must be mapped; ids already on
      # this visit may stay after the lead unmaps them.
      def write_attributes
        attributes = {}
        attributes[:visited_on] = params[:visited_on] if params.key?(:visited_on)
        attributes[:notes] = params[:notes] if params.key?(:notes)
        attributes[:project_ids] = params[:project_ids] if params.key?(:project_ids)
        attributes[:property_ids] = params[:property_ids] if params.key?(:property_ids)
        attributes
      end

      def set_lead
        @lead = Lead.visible_to(current_user).find_by(id: params[:lead_id])
        return if @lead

        render_error("not_found", "Lead not found", status: :not_found)
      end

      def set_visit
        @visit = @lead.lead_visits.find_by(id: params[:id])
        return if @visit

        render_error("not_found", "Visit not found", status: :not_found)
      end
    end
  end
end
