# frozen_string_literal: true

module Uploads
  # A signed_id is an attach token, not just a filename. POST /uploads stamps
  # firm_id and purpose on the blob; this is the check that actually uses them.
  # Without it a ticket issued for another firm, or for a looser purpose, attaches
  # as if it belonged here.
  class AcceptSignedId
    Result = Struct.new(:ok?, :blob, :error_code, :error_message, keyword_init: true)

    def initialize(signed_id:, firm:, purpose:)
      @signed_id = signed_id
      @firm = firm
      @purpose = purpose.to_s
    end

    def call
      blob = ActiveStorage::Blob.find_signed!(signed_id)

      unless blob.metadata["firm_id"].to_s == firm.id.to_s &&
             blob.metadata["purpose"].to_s == purpose
        return rejected
      end

      rejection = UploadPurpose.new(purpose).reject(
        byte_size: blob.byte_size, content_type: blob.content_type
      )
      if rejection
        return Result.new(ok?: false, error_code: rejection.code, error_message: rejection.message)
      end

      unless blob.service.exist?(blob.key)
        return Result.new(
          ok?: false,
          error_code: "upload_incomplete",
          error_message: "That upload didn't finish. Send the file to storage before attaching it."
        )
      end

      Result.new(ok?: true, blob:)
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
      rejected
    end

    private

    attr_reader :signed_id, :firm, :purpose

    # Same code as a tampered signed_id: a 404 here would confirm the blob exists
    # on another tenant, and a distinct "wrong purpose" code would teach the
    # client which attack to try next.
    def rejected
      Result.new(ok?: false, error_code: "invalid_upload",
                 error_message: "That isn't a valid upload.")
    end
  end
end
