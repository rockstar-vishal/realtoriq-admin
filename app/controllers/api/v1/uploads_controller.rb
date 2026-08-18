# frozen_string_literal: true

module Api
  module V1
    # Issues a direct-upload ticket: the client PUTs the file straight to
    # storage, then passes the returned `signed_id` when creating the record it
    # belongs to.
    #
    # Rails ships its own /rails/active_storage/direct_uploads, deliberately not
    # mounted here — it sits outside our JWT auth and enforces no per-purpose
    # size or type limits.
    class UploadsController < AuthenticatedController
      def create
        purpose = UploadPurpose.new(params[:purpose])

        rejection = purpose.reject(
          byte_size: params[:byte_size], content_type: params[:content_type]
        )

        if rejection
          status = rejection.code == "unknown_purpose" ? :bad_request : :unprocessable_content
          return render_error(rejection.code, rejection.message, status:)
        end

        blob = ActiveStorage::Blob.create_before_direct_upload!(
          filename: params.require(:filename),
          byte_size: params[:byte_size].to_i,
          checksum: params.require(:checksum),
          content_type: params[:content_type],
          # Records which tenant asked for the ticket. The blob is anonymous
          # until something attaches it, so without this an orphaned upload
          # can't be traced or swept.
          metadata: { firm_id: current_firm.id, purpose: purpose.name }
        )

        render json: {
          signed_id: blob.signed_id,
          direct_upload: {
            url: blob.service_url_for_direct_upload,
            headers: blob.service_headers_for_direct_upload
          },
          # Echoed back so the client can check its own limits before asking.
          purpose: purpose.name,
          max_bytes: purpose.max_bytes
        }, status: :created
      end
    end
  end
end
