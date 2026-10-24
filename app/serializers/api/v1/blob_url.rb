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

      def self.call(attachment, expires_in: nil, proxy: false)
        return nil if attachment.blank?

        blob = attachment.try(:blob) || attachment

        options = url_options
        options[:expires_in] = expires_in if expires_in

        helper = proxy ? :rails_storage_proxy_url : :rails_blob_url
        Rails.application.routes.url_helpers.public_send(helper, blob, **options)
      end

      # For anything a client should not be able to keep or forward.
      def self.sensitive(attachment) = call(attachment, expires_in: SENSITIVE_TTL)

      # Same lifetime as .call, but the bytes are streamed by this API instead
      # of a redirect to storage.
      #
      # pdf.js reads the guide with fetch(). The redirect answers 200 from S3
      # and omits Access-Control-Allow-Origin: the browser's follow-up request
      # does not present the app origin, and the bucket only adds that header
      # when the origin matches. A direct request to the bucket does carry it.
      # /rails/active_storage/* already allows the app, so the reader has to
      # stay on the API.
      def self.proxy(attachment) = call(attachment, proxy: true)

      # A smaller copy. The original stays on `.call` — share links are pasted
      # into WhatsApp and have to keep working if a variant is missing.
      def self.variant(attachment, name)
        return nil if attachment.blank?

        blob = attachment.try(:blob) || attachment
        return call(attachment) unless blob.variable?

        Rails.application.routes.url_helpers.rails_representation_url(
          attachment.variant(name), **url_options
        )
      end

      def self.photo(attachment)
        prepare(attachment)
        {
          id: attachment.id,
          url: call(attachment),
          thumb_url: variant(attachment, :thumb),
          large_url: variant(attachment, :large),
          width: dimension(attachment, "width"),
          height: dimension(attachment, "height")
        }
      end

      # Lists preload variant_records through with_attached_photos. Touching
      # the association is free when that preload ran, and one query per photo
      # when it did not — the list spec fails if the preload goes away.
      def self.prepare(attachment)
        blob = attachment&.try(:blob)
        return if blob.nil?

        records = blob.variant_records
        records.load unless records.loaded?
      end

      def self.dimension(attachment, key)
        meta = attachment.blob.metadata
        return nil if meta.blank?

        meta[key] || meta[key.to_sym]
      end

      def self.url_options
        # .dup matters: Hash#to_h returns self, so without it this writes
        # expires_in into ActiveStorage::Current.url_options and every later URL
        # in the same request inherits it — including the photo URLs that are
        # supposed to be permanent. A spec pins this.
        ActiveStorage::Current.url_options.presence.to_h.dup
      end
    end
  end
end
