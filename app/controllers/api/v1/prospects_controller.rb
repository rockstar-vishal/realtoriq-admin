# frozen_string_literal: true

module Api
  module V1
    class ProspectsController < AuthenticatedController
      before_action :set_prospect, only: %i[mobile update destroy move_to_following]

      def index
        scope = Prospect.includes(:project, :property, :lead)
        scope = if params[:q].present?
          scope.search(params[:q]).order(updated_at: :desc, id: :desc)
        else
          status = Prospect::STATUSES.include?(params[:status].to_s) ? params[:status].to_s : "new"
          scope.where(status:).merge(Prospect.ordered_for(status))
        end
        @pagy, records = pagy(scope, limit: per_page)
        Prospect.preload_latest_notes(records)
        render json: {
          prospects: records.map { |prospect| ProspectSerializer.card(prospect, current_user) },
          counts: Prospect.counts,
          can_clear: current_user.super_admin? || current_user.manager?,
          meta: pagination_meta(@pagy)
        }, status: :ok
      end

      def mobile
        render json: { mobile: @prospect.mobile }, status: :ok
      end

      def update
        result = ::Prospects::Update.new(prospect: @prospect, attributes: prospect_params).call
        render_prospect_result(result)
      end

      def destroy
        result = ::Prospects::Destroy.new(prospect: @prospect, actor: current_user).call
        return render_service_error(result) unless result.ok?

        head :no_content
      end

      def move_to_following
        result = ::Prospects::MoveToFollowing.new(prospect: @prospect, actor: current_user).call
        render_prospect_result(result)
      end

      def backup
        result = ::Prospects::Backup.new(actor: current_user, statuses: params[:statuses]).call
        return render_service_error(result) unless result.ok?

        send_data result.csv, filename: "prospects-backup.csv", type: "text/csv; charset=utf-8",
          disposition: "attachment"
      end

      def clear
        result = ::Prospects::Clear.new(firm: current_firm, actor: current_user, statuses: params[:statuses]).call
        return render_service_error(result) unless result.ok?

        render json: { deleted_count: result.deleted_count }, status: :ok
      end

      private

      def set_prospect
        @prospect = Prospect.find(params[:id])
      end

      def prospect_params
        params.permit(:name, :mobile, :comment, :project_id, :property_id)
      end

      def per_page
        requested = params[:per_page].to_i
        return 25 if requested <= 0

        requested.clamp(1, 50)
      end

      def render_prospect_result(result, status: :ok)
        return render_service_error(result) unless result.ok?

        render json: { prospect: ProspectSerializer.card(reload_prospect(result.prospect), current_user) }, status:
      end

      def render_service_error(result)
        status = result.error_code == "forbidden_role" ? :forbidden : :unprocessable_content
        render_error(result.error_code, result.error_message, status:, details: result.try(:error_details))
      end

      def reload_prospect(prospect)
        record = Prospect.includes(:project, :property, :lead).find(prospect.id)
        Prospect.preload_latest_notes([ record ])
        record
      end
    end
  end
end
