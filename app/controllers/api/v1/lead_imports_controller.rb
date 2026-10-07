# frozen_string_literal: true

module Api
  module V1
    class LeadImportsController < AuthenticatedController
      MAX_BYTES = 1.megabyte

      def template
        send_data ::Leads::Import.template,
          filename: "leads-import-sample.csv",
          type: "text/csv; charset=utf-8",
          disposition: "attachment"
      end

      def create
        upload = params[:file]
        if upload.blank? || !upload.respond_to?(:read)
          return render_error("invalid", "Choose a CSV file to import.", status: :unprocessable_content)
        end
        if upload.respond_to?(:size) && upload.size > MAX_BYTES
          return render_error("invalid", "That file is larger than 1 MB. Split it and import the parts.",
            status: :unprocessable_content)
        end
        if upload.respond_to?(:original_filename) && upload.original_filename.to_s.match?(/\.xlsx\z/i)
          return render_error("invalid",
            "This is an Excel workbook. Save it as CSV UTF-8 (comma separated) and upload that file.",
            status: :unprocessable_content)
        end

        result = ::Leads::Import.new(firm: current_firm, actor: current_user, io: upload.read).call
        if result.file_error
          return render_error("invalid", result.file_error, status: :unprocessable_content)
        end

        render json: result.as_json, status: :ok
      end
    end
  end
end
