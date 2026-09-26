# frozen_string_literal: true

module Api
  module V1
    # Nested under a lead. Flat controller name so Api::V1::Leads does not
    # shadow the Leads:: service namespace (same reason as activities).
    class LeadFollowupsController < AuthenticatedController
      before_action :set_lead

      def index
        @pagy, records = pagy(
          @lead.lead_followups.includes(:user).recent_first, limit: 25
        )

        render json: {
          followups: records.map { |f| LeadFollowupSerializer.call(f) },
          meta: pagination_meta(@pagy)
        }, status: :ok
      end

      def create
        result = ::Leads::RecordFollowup.new(
          lead: @lead,
          actor: current_user,
          comment: params[:comment],
          next_action_at: params[:next_action_at],
          status: params[:status],
          reason: params[:reason],
          booked_on: params[:booked_on]
        ).call

        unless result.ok?
          details = result.errors&.to_hash
          return render_error(result.error_code, result.error_message,
                              status: :unprocessable_content, details:)
        end

        lead = result.lead
        Lead.preload_card_extras([ lead ])

        render json: {
          followup: LeadFollowupSerializer.call(result.followup),
          lead: LeadSerializer.list(lead)
        }, status: :created
      end

      private

      def set_lead
        @lead = Lead.visible_to(current_user).find_by(id: params[:lead_id])
        return if @lead

        render_error("not_found", "Lead not found", status: :not_found)
      end
    end
  end
end
