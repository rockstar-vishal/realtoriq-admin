# frozen_string_literal: true

require "openssl"
require "combine_pdf"

module Realtoriq
  # Makes project_creatives match the creatives array on one push. A missing
  # key never reaches here. An empty array removes the set.
  class SyncProjectCreatives
    MAX_PDF_PAGES = 5
    TYPES = (RemoteFile::IMAGE_TYPES + RemoteFile::BROCHURE_TYPES).freeze
    Plan = Data.define(
      :external_id, :title, :position, :numbers, :checksum, :blob, :kind, :page_count, :failed,
      :valid_until, :valid_until_ok, :video_url, :video_provider
    )
    Prepared = Data.define(:plans, :blobs)
    Dated = Data.define(:date, :ok)

    def self.prepare(project, rows)
      new(project, rows).prepare
    end

    def self.apply(project, prepared)
      ids = prepared.plans.map(&:external_id)
      project.project_creatives.where.not(external_id: ids).find_each do |row|
        row.file.purge_later if row.file.attached?
        row.destroy!
      end
      prepared.plans.each { |plan| apply_one(project, plan) }
    end

    def self.apply_one(project, plan)
      record = project.project_creatives.find_or_initialize_by(external_id: plan.external_id)
      return if plan.failed && record.new_record?

      record.title = plan.title
      record.position = plan.position
      record.registration_numbers = plan.numbers
      record.valid_until = plan.valid_until if plan.valid_until_ok
      if plan.kind == "video"
        apply_video(record, plan)
      elsif plan.blob
        apply_file(record, plan)
      elsif record.new_record?
        return
      end
      record.save!
    end

    # A file that becomes a video drops the file and every firm's copy of it.
    # A video that becomes a file is downloaded like any other new file.
    def self.apply_video(record, plan)
      unless record.video?
        drop_personalised(record)
        detach_file(record)
      end
      record.kind = "video"
      record.video_url = plan.video_url
      record.video_provider = plan.video_provider
      record.checksum = nil
      record.page_count = nil
    end

    def self.apply_file(record, plan)
      if record.video?
        drop_personalised(record)
        record.video_url = nil
        record.video_provider = nil
      end
      record.kind = plan.kind
      record.page_count = plan.page_count
      record.checksum = plan.checksum
      record.file.attach(plan.blob)
    end

    def self.drop_personalised(record)
      return unless record.persisted?

      PersonalisedCreative.across_firms.where(project_creative_id: record.id).find_each do |copy|
        copy.file.purge_later if copy.file.attached?
        copy.destroy!
      end
    end

    def self.detach_file(record)
      return unless record.file.attached?

      blob = record.file.blob
      record.file.detach
      blob.purge_later
    end

    def initialize(project, rows)
      @project = project
      @rows = rows.is_a?(Array) ? rows : []
    end

    def prepare
      blobs = []
      plans = wanted.filter_map { |row| plan_for(row, blobs) }
      Prepared.new(plans:, blobs:)
    end

    private

    attr_reader :project, :rows

    def wanted
      rows.filter_map { |row|
        data = row.to_h.stringify_keys
        data if data["id"].present?
      }.reverse.uniq { |row| row["id"] }.reverse
    end

    def plan_for(row, blobs)
      existing = project.project_creatives.find_by(external_id: row["id"])
      dating = valid_until_for(row)
      base = {
        external_id: row["id"],
        title: row["title"].to_s.strip.presence || "Creative",
        position: row["position"].to_i,
        numbers: Array(row["registration_numbers"]).map { |number| number.to_s.strip.upcase }.reject(&:blank?),
        checksum: row["checksum"].to_s,
        blob: nil, kind: nil, page_count: nil, failed: false,
        valid_until: dating.date, valid_until_ok: dating.ok, video_url: nil, video_provider: nil
      }
      unless dating.ok
        log(row["id"], "valid until was not a date")
        return Plan.new(**base.merge(failed: true))
      end

      return video_plan(row, base) if video?(row)

      if row["url"].blank? || row["checksum"].blank?
        log(row["id"], "missing file")
        return Plan.new(**base.merge(failed: true))
      end
      if existing&.file&.attached? && current_copy?(existing.file.blob, row["checksum"])
        return Plan.new(**base.merge(kind: existing.kind, page_count: existing.page_count))
      end

      downloaded = fetch(row)
      if downloaded.nil?
        return Plan.new(**base.merge(failed: true))
      end

      blobs << downloaded[0]
      Plan.new(**base.merge(blob: downloaded[0], kind: downloaded[1], page_count: downloaded[2]))
    end

    def video?(row)
      kind = row["kind"].to_s.strip.downcase
      return true if kind == "video"
      return false if %w[image pdf].include?(kind)

      row["video_url"].present? && row["url"].blank?
    end

    def video_plan(row, base)
      link = Marketing::VideoLink.parse(row["video_url"])
      unless link
        log(row["id"], "video link was rejected")
        return Plan.new(**base.merge(failed: true))
      end

      Plan.new(**base.merge(kind: "video", checksum: nil, video_url: link.url, video_provider: link.provider))
    end

    # Blank or missing means no end date. A value that is not an ISO date
    # fails the row, and the stored date is left alone.
    def valid_until_for(row)
      raw = row["valid_until"]
      return Dated.new(nil, true) if raw.blank?

      Dated.new(Date.iso8601(raw.to_s), true)
    rescue ArgumentError
      Dated.new(nil, false)
    end

    def fetch(row)
      io = nil
      io = download(row)
      return if io.nil?

      kind = kind_of(row, io)
      pages = nil
      if kind == "pdf"
        pages = page_count(io)
        if pages.nil? || pages > MAX_PDF_PAGES
          log(row["id"], pages.nil? ? "pdf could not be read" : "pdf has more than 5 pages")
          return
        end
      end
      type = content_type(row, kind)
      filename = row["filename"].presence || (kind == "pdf" ? "creative.pdf" : "creative.jpg")
      blob = ActiveStorage::Blob.create_and_upload!(io:, filename:, content_type: type)
      [ blob, kind, pages ]
    rescue RemoteFile::TypeError
      log(row["id"], "file type is not allowed")
      nil
    ensure
      io.close! if io.is_a?(Tempfile)
    end

    def download(row)
      io = RemoteFile.fetch(row["url"], content_types: TYPES)
      actual = checksum_of(io)
      if actual != row["checksum"]
        io.close! if io.is_a?(Tempfile)
        raise RemoteFile::Error, "checksum did not match"
      end
      return StringIO.new(io) if io.is_a?(String)

      io.rewind
      io
    end

    def kind_of(row, io)
      type = row["content_type"].to_s.split(";").first.to_s.strip.downcase
      return "pdf" if type == "application/pdf" || peek(io).start_with?("%PDF")

      "image"
    end

    def content_type(row, kind)
      type = row["content_type"].to_s.split(";").first.to_s.strip.downcase
      return type if TYPES.include?(type)

      kind == "pdf" ? "application/pdf" : "image/jpeg"
    end

    def page_count(io)
      bytes = io.is_a?(String) ? io.dup : io.read
      io.rewind if io.respond_to?(:rewind)
      CombinePDF.parse(bytes).pages.size
    rescue StandardError
      nil
    end

    def peek(io)
      return io.byteslice(0, 5).to_s if io.is_a?(String)

      io.rewind
      bytes = io.read(5).to_s
      io.rewind
      bytes
    end

    def current_copy?(blob, checksum)
      blob.present? && blob.checksum == checksum && blob.service_name == ActiveStorage::Blob.service.name.to_s
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

    def log(external_id, reason)
      Rails.logger.warn("Project creative skipped (#{project.code} #{external_id}): #{reason}")
    end
  end
end
