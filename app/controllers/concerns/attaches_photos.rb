# frozen_string_literal: true

# Photos arrive as `signed_id`s from POST /uploads, which has already enforced
# the size and content-type rules for their purpose. By the time a photo reaches
# here the file is in storage; this only records what it belongs to.
#
# Shared by projects and properties, which handle photos identically — the
# design puts the gallery on the detail screen for both.
module AttachesPhotos
  extend ActiveSupport::Concern

  MAX_PHOTOS = 20

  private

  def attach_photos(record, signed_ids)
    ids = Array(signed_ids).compact_blank
    return render_error("no_photos", "Send at least one signed_id.", status: :bad_request) if ids.empty?

    if record.photos.attachments.size + ids.size > MAX_PHOTOS
      return render_error("too_many_photos",
                          "A listing can hold #{MAX_PHOTOS} photos.",
                          status: :unprocessable_content)
    end

    record.photos.attach(ids)
    yield
  rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
    # A signed_id that doesn't verify is a client bug or a tampered value —
    # either way there is no file to attach.
    render_error("invalid_upload", "One of those uploads isn't valid.", status: :unprocessable_content)
  rescue ActiveStorage::FileNotFoundError
    # The ticket was issued but the file never reached storage — the client's
    # PUT failed, or it attached before the upload finished. A real case, and a
    # 422 the client can act on rather than a 500.
    render_error("upload_incomplete",
                 "That upload didn't finish. Send the file to storage before attaching it.",
                 status: :unprocessable_content)
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
