# frozen_string_literal: true

module Api
  module V1
    # One place that turns an attachment into a URL a client can fetch.
    #
    # `rails_blob_url` rather than the service URL directly: the service URL is
    # signed and expires in minutes, which is wrong for a payload a client may
    # hold and re-render.
    #
    # **That reasoning holds for photos and not for anything else.** Photos are
    # meant to outlive the response — `shareable` exists so a broker can paste
    # one into WhatsApp — but a booking document is a commission record and a
    # collection proof is evidence of a payment, and Rails serves both from
    # ActiveStorage::Blobs::RedirectController, which has no authentication at
    # all. A permanent URL for those is a permanent unauthenticated URL: anyone
    # it is ever forwarded to keeps access forever, and revoking means deleting
    # the file.
    #
    # So sensitive attachments pass `expires_in`. The signed id then carries an
    # expiry and the link stops working on its own; the client re-fetches the
    # parent record to get a fresh one.
    module BlobUrl
      # Long enough to open a PDF or hand to a viewer, short enough that a
      # forwarded link is worthless by the time it arrives.
      SENSITIVE_TTL = 15.minutes

      def self.call(attachment, expires_in: nil)
        return nil if attachment.blank?

        blob = attachment.try(:blob) || attachment

        # .dup matters: Hash#to_h returns self, so without it this writes
        # expires_in into ActiveStorage::Current.url_options and every later URL
        # in the same request inherits it — including the photo URLs that are
        # supposed to be permanent. A spec pins this.
        options = ActiveStorage::Current.url_options.presence.to_h.dup
        options[:expires_in] = expires_in if expires_in

        Rails.application.routes.url_helpers.rails_blob_url(blob, **options)
      end

      # For anything a client should not be able to keep or forward.
      def self.sensitive(attachment) = call(attachment, expires_in: SENSITIVE_TTL)
    end
  end
end
