# frozen_string_literal: true

module Api
  module V1
    # MahaRERA Form 6. Managers and the super admin, like bookings.
    # GET settings answers for every firm. The rest are Maharashtra only.
    class Form6Controller < AuthenticatedController
      before_action :require_manager
      before_action :require_available, except: :show

      def show
        render json: ::Form6::Settings.payload(current_firm), status: :ok
      end

      def update
        result = ::Form6::Settings.apply(firm: current_firm, incoming: params.to_unsafe_h)
        unless result.ok?
          return render_error("invalid", result.message, status: :unprocessable_content, details: result.details)
        end

        current_firm.update!(form6: result.settings)
        render json: ::Form6::Settings.payload(current_firm), status: :ok
      end

      def preview
        period = completed_period
        return if period.nil?

        render json: ::Form6::Preview.new(firm: current_firm, period:).as_json, status: :ok
      end

      def download
        period = completed_period
        return if period.nil?

        document = ::Form6::Document.new(firm: current_firm, period:)
        send_data document.to_docx, filename: document.filename, type: ::Form6::Document::CONTENT_TYPE,
          disposition: "attachment"
      end

      private

      def require_manager
        return if current_user.super_admin? || current_user.manager?

        render_error("forbidden_role", "Only a manager can work with bookings.", status: :forbidden)
      end

      def require_available
        return if current_firm.form6_available?

        render_error("form6_unavailable", "Form 6 is for firms in Maharashtra.", status: :forbidden)
      end

      def completed_period
        period = ::Form6::Period.parse(params[:period])
        return period if period&.ended?

        render_error("invalid", "Choose a completed half-year.", status: :unprocessable_content)
        nil
      end
    end
  end
end
