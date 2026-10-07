# frozen_string_literal: true

module Api
  module V1
    module Facebook
      class ImportsController < BaseController
        PAGE_SIZE = 20

        def index
          page = params[:page].to_i
          page = 1 if page < 1
          scope = current_firm.facebook_lead_imports.recent
          rows = scope.includes(:facebook_page, :facebook_lead_form, :lead)
            .offset((page - 1) * PAGE_SIZE).limit(PAGE_SIZE)
          render json: {
            imports: rows.map { |row| import_json(row) },
            page:,
            total: scope.count
          }
        end

        def retry
          import = current_firm.facebook_lead_imports.find_by(id: params[:id])
          return not_found if import.nil?
          unless import.queue_retry!
            return render_error("not_retryable", "This import cannot be retried.", status: :unprocessable_entity)
          end

          render json: { import: import_json(import.reload) }
        end

        def retry_failed
          count = 0
          current_firm.facebook_lead_imports.where(status: %w[failed dead]).find_each do |import|
            count += 1 if import.queue_retry!
          end
          render json: { retried: count }
        end

        private

        def import_json(row)
          {
            "id" => row.id,
            "leadgen_id" => row.leadgen_id,
            "status" => row.status,
            "retry_count" => row.retry_count,
            "error_message" => row.error_message,
            "created_at" => row.created_at&.iso8601,
            "processed_at" => row.processed_at&.iso8601,
            "page_name" => row.facebook_page&.page_name,
            "form_name" => row.facebook_lead_form&.form_name,
            "lead_id" => row.lead_id,
            "lead_code" => row.lead&.code
          }
        end
      end
    end
  end
end
