# frozen_string_literal: true

require "openssl"

module Realtoriq
  # Copies brochure and photos after the listing itself is saved. A file whose
  # checksum is already attached is left alone, so a brief that already went
  # out keeps its brochure URL.
  class SyncProjectAssets
    def self.call(project:, images:, brochure:, pushed_at: nil, brokerage_ladder: nil)
      new(project:, images:, brochure:, pushed_at:, brokerage_ladder:).call
    end

    def initialize(project:, images:, brochure:, pushed_at: nil, brokerage_ladder: nil)
      @project = project
      @images = Array(images)
      @brochure = brochure
      @pushed_at = pushed_at
      @brokerage_ladder = brokerage_ladder
    end

    def call
      brochure_blob = nil
      ladder_blob = nil
      image_blobs = []
      applied = false
      return if stale?(Project.unscoped.find_by(id: project.id))

      brochure_blob = safe_upload { upload_brochure }
      ladder_blob = upload_ladder
      upload_images(image_blobs)
      Project.unscoped.transaction do
        locked = Project.unscoped.lock.find_by(id: project.id)
        if locked.nil? || stale?(locked)
          raise ActiveRecord::Rollback
        end

        apply_brochure(locked, brochure_blob)
        apply_ladder(locked, ladder_blob)
        apply_images(locked, image_blobs)
        applied = true
      end
    ensure
      discard_unused(brochure_blob, ladder_blob, image_blobs) unless applied
    end

    private

    attr_reader :project, :images, :brochure, :pushed_at, :brokerage_ladder

    # A retry of an older push must not put yesterday's photos over a newer set.
    # Checked again under a row lock, after the downloads, so a slow fetch cannot
    # land on top of a push that arrived while it was running.
    def stale?(row)
      return true if row.nil?
      return false if pushed_at.nil? || row.turbo_pushed_at.blank?

      row.turbo_pushed_at > pushed_at
    end

    # A brochure that cannot be fetched must not drop the ladder image.
    def safe_upload
      yield
    rescue RemoteFile::Error
      :omit
    end

    def upload_brochure
      # nil means this push is not copying a brochure. Do not purge: the
      # marketplace link lives on the project, and a failed download must
      # not block the ladder image that runs next.
      return :omit if brochure.nil?

      wanted = file_row(brochure)
      return :absent if wanted.nil?
      return :unchanged if current_copy?(project.brochure.blob, wanted["checksum"])

      upload(wanted, RemoteFile::BROCHURE_TYPES, "brochure.pdf")
    end

    def upload_ladder
      return :omit if brokerage_ladder.nil?

      wanted = file_row(brokerage_ladder)
      return :absent if wanted.nil?
      return :unchanged if current_copy?(project.brokerage_ladder.blob, wanted["checksum"])

      upload(wanted, RemoteFile::IMAGE_TYPES, "ladder.jpg")
    end

    def upload_images(into)
      images.filter_map { |row| file_row(row) }.each do |row|
        next if attached_image_checksums.include?(row["checksum"])

        into << upload(row, RemoteFile::IMAGE_TYPES, "photo")
      end
    end

    def attached_image_checksums
      @attached_image_checksums ||= project.photos.blobs.select { |blob| current_copy?(blob, blob.checksum) }.map(&:checksum)
    end

    # A matching checksum on the disk service is not a copy we can serve in
    # production. Those URLs 404 once the file is no longer on that machine.
    def current_copy?(blob, checksum)
      blob.present? && blob.checksum == checksum && blob.service_name == ActiveStorage::Blob.service.name.to_s
    end

    def upload(row, content_types, fallback)
      io = download(row, content_types)
      ActiveStorage::Blob.create_and_upload!(io:, filename: filename(row, fallback))
    ensure
      io.close! if io.is_a?(Tempfile)
    end

    def apply_brochure(locked, blob)
      return if blob == :omit

      if blob == :absent
        locked.brochure.purge_later if locked.brochure.attached?
        return
      end
      return if blob == :unchanged || !blob.is_a?(ActiveStorage::Blob)
      return if current_copy?(locked.brochure.blob, blob.checksum)

      locked.brochure.attach(blob)
    end

    def apply_ladder(locked, blob)
      return if blob == :omit

      if blob == :absent
        locked.brokerage_ladder.purge_later if locked.brokerage_ladder.attached?
        return
      end
      return if blob == :unchanged || !blob.is_a?(ActiveStorage::Blob)
      return if current_copy?(locked.brokerage_ladder.blob, blob.checksum)

      locked.brokerage_ladder.attach(blob)
    end

    def apply_images(locked, blobs)
      wanted = images.filter_map { |row| file_row(row) }
      checksums = wanted.map { |row| row["checksum"] }
      attachments = locked.photos.attachments.includes(:blob).to_a
      attachments.each do |attachment|
        attachment.purge_later unless current_copy?(attachment.blob, attachment.blob.checksum) &&
          checksums.include?(attachment.blob.checksum)
      end

      kept = attachments.select { |attachment| current_copy?(attachment.blob, attachment.blob.checksum) }
      attached_ids = kept.map(&:blob_id)
      seen = kept.map { |attachment| attachment.blob.checksum }
      blobs.each do |blob|
        if seen.include?(blob.checksum)
          blob.purge_later unless attached_ids.include?(blob.id)
          next
        end

        locked.photos.attach(blob)
        seen << blob.checksum
        attached_ids << blob.id
      end
    end

    def discard_unused(brochure_blob, ladder_blob, image_blobs)
      brochure_blob.purge_later if brochure_blob.is_a?(ActiveStorage::Blob)
      ladder_blob.purge_later if ladder_blob.is_a?(ActiveStorage::Blob)
      Array(image_blobs).each { |blob| blob.purge_later if blob.is_a?(ActiveStorage::Blob) }
    end

    def file_row(row)
      return if row.blank?

      data = row.to_h.deep_stringify_keys
      return if data["url"].blank? || data["checksum"].blank?

      data
    end

    def download(row, content_types)
      io = RemoteFile.fetch(row["url"], content_types:)
      actual = checksum_of(io)
      if actual != row["checksum"]
        io.close! if io.is_a?(Tempfile)
        raise RemoteFile::Error, "checksum did not match"
      end
      return StringIO.new(io) if io.is_a?(String)

      io.rewind
      io
    end

    def checksum_of(io)
      return OpenSSL::Digest::MD5.base64digest(io) if io.is_a?(String)

      digest = OpenSSL::Digest::MD5.new
      io.rewind
      while (chunk = io.read(64.kilobytes))
        digest << chunk
      end
      Base64.strict_encode64(digest.digest)
    end

    def filename(row, fallback)
      row["filename"].presence || fallback
    end
  end
end
