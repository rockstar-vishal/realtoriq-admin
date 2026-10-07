# frozen_string_literal: true

require "digest"

module Storage
  # Copies one blob's bytes from the disk service onto S3 and points the row
  # at S3. A disk URL 404s when the file is not on this machine; after this,
  # the same blob redirects to the bucket.
  class PromoteToS3
    def self.call(blob:, source:, destination:, destination_name:)
      path = source.path_for(blob.key)
      return :missing unless File.exist?(path)

      digest = Digest::MD5.file(path).base64digest
      return :checksum unless digest == blob.checksum

      File.open(path, "rb") do |io|
        destination.upload(
          blob.key, io,
          checksum: blob.checksum,
          filename: blob.filename.to_s,
          content_type: blob.content_type
        )
      end
      blob.update_columns(service_name: destination_name)
      :promoted
    end
  end
end
