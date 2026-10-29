# frozen_string_literal: true

require "openssl"
require "combine_pdf"

module Realtoriq
  # Makes project_creatives match the creatives array on one push. A missing
  # key never reaches here. An empty array removes the set.
  class SyncProjectCreatives
    MAX_PDF_PAGES = 5
    TYPES = (RemoteFile::IMAGE_TYPES + RemoteFile::BROCHURE_TYPES).freeze
    Plan = Data.define(:external_id, :title, :position, :numbers, :checksum, :blob, :kind, :page_count, :failed)
    Prepared = Data.define(:plans, :blobs)

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
      if plan.blob
        record.kind = plan.kind
        record.page_count = plan.page_count
        record.checksum = plan.checksum
        record.file.attach(plan.blob)
      elsif record.new_record?
        return
      end
      record.save!
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
      base = {
        external_id: row["id"],
        title: row["title"].to_s.strip.presence || "Creative",
        position: row["position"].to_i,
        numbers: Array(row["registration_numbers"]).map { |number| number.to_s.strip.upcase }.reject(&:blank?),
        checksum: row["checksum"].to_s,
        blob: nil, kind: nil, page_count: nil, failed: false
      }
      if row["url"].blank? || row["checksum"].blank?
        log(row["id"], "missing file")
        return Plan.new(**base.merge(failed: true))
      end
      if existing && current_copy?(existing.file.blob, row["checksum"])
        return Plan.new(**base.merge(kind: existing.kind, page_count: existing.page_count))
      end

      downloaded = fetch(row)
      if downloaded.nil?
        return Plan.new(**base.merge(failed: true))
      end

      blobs << downloaded[0]
      Plan.new(**base.merge(blob: downloaded[0], kind: downloaded[1], page_count: downloaded[2]))
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
      Rails.logger.warn("Project creative skipped (#{project.external_ref} #{external_id}): #{reason}")
    end
  end
end
