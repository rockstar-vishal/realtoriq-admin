# frozen_string_literal: true

module Api
  module V1
    class ReportsController < AuthenticatedController
      before_action :require_manager, only: %i[bookings revenue]

      def source_status
        respond_with(:source_status, ::Reports::SourceStatus.new(user: current_user, params:).call)
      end

      def dead_leads
        respond_with(:dead_leads, ::Reports::DeadLeads.new(user: current_user, params:).call)
      end

      def bookings
        respond_with(:bookings, ::Reports::Bookings.new(user: current_user, params:).call)
      end

      def revenue
        respond_with(:revenue, ::Reports::Revenue.new(user: current_user, params:).call)
      end

      # Not GET /users. That list is a manager's reporting line, and a
      # manager's lead report is the whole firm.
      def assignees
        users = if current_user.super_admin? || current_user.manager?
          current_firm.users.order(:name)
        else
          current_firm.users.where(id: current_user.id)
        end

        render json: {
          users: users.map { |user| { id: user.id, name: user.name, role: user.role, status: user.status } }
        }, status: :ok
      end

      private

      def require_manager
        return if current_user.super_admin? || current_user.manager?

        render_error("forbidden_role", "Only a manager can work with bookings.", status: :forbidden)
      end

      def respond_with(kind, result)
        unless result.ok?
          return render_error("invalid", result.error_message, status: :unprocessable_content)
        end

        if params[:export].to_s == "csv"
          send_data ::Reports::Table.csv(kind, result.payload),
            type: "text/csv",
            disposition: "attachment",
            filename: ::Reports::Table.filename(kind, result.payload)
        else
          render json: result.payload, status: :ok
        end
      end
    end
  end
end
