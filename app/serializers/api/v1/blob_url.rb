# frozen_string_literal: true

module Api
  module V1
    # One place that turns an attachment into a URL a client can fetch.
    #
    # `rails_blob_url` rather than the service URL directly: the service URL is
    # signed and expires in minutes, which is wrong for a payload a client may
    # hold and re-render. This one is stable and redirects.
    module BlobUrl
      def self.call(attachment)
        return nil if attachment.blank?

        blob = attachment.try(:blob) || attachment

        Rails.application.routes.url_helpers.rails_blob_url(
          blob, **ActiveStorage::Current.url_options.presence.to_h
        )
      end
    end
  end
end
