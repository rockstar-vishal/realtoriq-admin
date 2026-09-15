# frozen_string_literal: true

# Photos arrive as `signed_id`s from POST /uploads. The ticket already enforced
# size and type for *its* purpose; attach-time still checks firm, purpose and
# that the PUT landed — a signed_id is an attach token, and the blob URL in a
# response is the same token.
#
# Shared by projects and properties, which handle photos identically — the
# design puts the gallery on the detail screen for both.
module AttachesPhotos
  extend ActiveSupport::Concern

  MAX_PHOTOS = 20

  private

  def attach_photos(record, signed_ids, purpose:)
    ids = Array(signed_ids).compact_blank
    return render_error("no_photos", "Send at least one signed_id.", status: :bad_request) if ids.empty?

    if record.photos.attachments.size + ids.size > MAX_PHOTOS
      return render_error("too_many_photos",
                          "A listing can hold #{MAX_PHOTOS} photos.",
                          status: :unprocessable_content)
    end

    results = ids.map do |signed_id|
      Uploads::AcceptSignedId.new(signed_id:, firm: current_firm, purpose:).call
    end
    failed = results.find { |result| !result.ok? }
    if failed
      return render_error(failed.error_code, failed.error_message, status: :unprocessable_content)
    end

    record.photos.attach(results.map(&:blob))
    yield
  end

  def detach_photo(record, attachment_id)
    attachment = record.photos.attachments.find_by(id: attachment_id)
    return render_error("not_found", "Photo not found", status: :not_found) if attachment.nil?

    # purge_later, not just detach: an unreferenced blob would sit in storage
    # being paid for forever.
    attachment.purge_later
    yield
  end
end
