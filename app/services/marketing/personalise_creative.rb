# frozen_string_literal: true

require "zlib"

module Marketing
  # One firm's footer on a catalog creative. A repeated call with the same
  # details returns the file already stored.
  class PersonaliseCreative
    VERSION = "mk2c-1"
    Result = Data.define(:payload, :lines, :cached)

    def self.call(creative:, firm:)
      new(creative:, firm:).call
    end

    def self.fingerprint(creative:, firm:, project:, numbers:)
      contacts = FirmContacts.new(firm)
      Digest::SHA256.hexdigest([
        VERSION,
        creative.checksum.to_s,
        firm.name.to_s,
        logo_checksum(firm),
        contacts.mobile.to_s,
        contacts.whatsapp.to_s,
        firm.rera_number.to_s,
        contacts.authority(project),
        Array(numbers).join(",")
      ].join("\n"))
    end

    def self.numbers_for(creative, project)
      listed = Array(creative.registration_numbers).map { |number| number.to_s.strip }.reject(&:blank?)
      return listed if listed.any?

      Registrations.for(project).map { |row| row["number"] }
    end

    def self.logo_checksum(firm)
      return "" unless firm.logo.attached?

      firm.logo.blob.checksum.to_s
    end

    def initialize(creative:, firm:)
      @creative = creative
      @firm = firm
    end

    def call
      project = Project.unscoped.includes(:city).find(creative.project_id)
      numbers = self.class.numbers_for(creative, project)
      fingerprint = self.class.fingerprint(creative:, firm:, project:, numbers:)
      with_lock do
        cached = PersonalisedCreative.across_firms.find_by(
          firm_id: firm.id, project_creative_id: creative.id, fingerprint:
        )
        if cached&.file&.attached?
          return Result.new(payload: payload_for(cached), lines: layout_lines(project, numbers), cached: true)
        end

        rendered = render(project, numbers)
        row = PersonalisedCreative.create!(project_creative: creative, firm:, fingerprint:)
        row.file.attach(io: StringIO.new(rendered.bytes), filename: rendered.filename, content_type: rendered.content_type)
        purge_older(row)
        Result.new(payload: payload_for(row), lines: rendered.lines, cached: false)
      end
    end

    private

    attr_reader :creative, :firm

    def with_lock
      key = Zlib.crc32("#{creative.id}:#{firm.id}")
      PersonalisedCreative.transaction do
        PersonalisedCreative.connection.execute("SELECT pg_advisory_xact_lock(#{key.to_i})")
        yield
      end
    end

    def render(project, numbers)
      logo = logo_path
      creative.file.blob.open do |file|
        if creative.pdf?
          bytes, lines = FooterPdf.apply(file.path, firm:, project:, numbers:, logo_path: logo)
          Rendered.new(bytes:, lines:, filename: filename("pdf"), content_type: "application/pdf")
        else
          composed = FooterImage.compose(file.path, firm:, project:, numbers:, logo_path: logo)
          png = composed.image.has_alpha?
          bytes = png ? composed.image.write_to_buffer(".png") : composed.image.write_to_buffer(".jpg", Q: 88, strip: true)
          Rendered.new(
            bytes:, lines: composed.lines,
            filename: filename(png ? "png" : "jpg"),
            content_type: png ? "image/png" : "image/jpeg"
          )
        end
      end
    ensure
      @logo_temp&.close!
    end

    def layout_lines(project, numbers)
      FooterLayout.call(
        width: 1000, firm:, project:, numbers:, logo_size: nil,
        measurer: ->(_text, _size, _weight) { 10 }
      ).lines.map(&:text)
    end

    def filename(ext)
      project = Project.unscoped.find(creative.project_id)
      "#{slug(project.name)}-#{slug(creative.title)}-#{firm.slug}.#{ext}"
    end

    def slug(text)
      text.to_s.parameterize.presence || "item"
    end

    def logo_path
      return unless firm.logo.attached?

      @logo_temp = Tempfile.new([ "firm-logo", ".png" ])
      @logo_temp.binmode
      @logo_temp.write(firm.logo.download)
      @logo_temp.flush
      @logo_temp.path
    end

    def purge_older(row)
      PersonalisedCreative.across_firms.where(firm_id: firm.id, project_creative_id: creative.id).where.not(id: row.id).find_each do |old|
        old.file.purge_later if old.file.attached?
        old.destroy!
      end
    end

    def payload_for(row)
      blob = row.file.blob
      {
        url: Api::V1::BlobUrl.proxy(row.file),
        filename: blob.filename.to_s,
        content_type: blob.content_type,
        byte_size: blob.byte_size
      }
    end

    Rendered = Data.define(:bytes, :lines, :filename, :content_type)
  end
end
