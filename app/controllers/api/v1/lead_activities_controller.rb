# frozen_string_literal: true

module Api
  module V1
    # The lead's timeline.
    #
    # Deliberately not namespaced under an `Api::V1::Leads` module: that module
    # would shadow the top-level `Leads::` service namespace inside every
    # controller here, and `Leads::Create` would silently resolve to the wrong
    # constant.
    class LeadActivitiesController < AuthenticatedController
      before_action :set_lead

      def index
        @pagy, records = pagy(
          @lead.lead_activities.includes(:user).recent_first, limit: 25
        )

        render json: {
          activities: records.map { |a| LeadActivitySerializer.call(a) },
          meta: pagination_meta(@pagy)
        }, status: :ok
      end

      def create
        result = ::Leads::RecordActivity.new(
          lead: @lead,
          actor: current_user,
          kind: params[:kind],
          body: params[:body],
          occurred_at: params[:occurred_at],
          outcome: params[:outcome]
        ).call

        unless result.ok?
          return render_error("invalid", result.errors.full_messages.to_sentence,
                              status: :unprocessable_content, details: result.errors.to_hash)
        end

        render json: {
          activity: LeadActivitySerializer.call(result.activity),
          # A visit sets first_visit_at, so the client can refresh the badge
          # without a second request.
          lead: LeadSerializer.list(@lead.reload)
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
