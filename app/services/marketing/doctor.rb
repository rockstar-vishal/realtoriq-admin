# frozen_string_literal: true

module Marketing
  # One line per check. A warning about PDF thumbnails does not fail the run.
  class Doctor
    def self.call(directory = Rails.root.join("tmp/mk2-doctor"))
      new(directory).call
    end

    def initialize(directory)
      @directory = directory
    end

    def call
      rows = [ vips, vips_cache, inter, devanagari, fc_scan, preview, gems, samples ]
      [ rows.map { |row| row[:line] }, rows.any? { |row| row[:failed] } ]
    end

    private

    def vips
      require "vips"
      version = Vips.version_string
      image = Fonts.render("A", size: 24, weight: :regular)
      line = image.width.positive? ? "vips: #{version} pango ok" : "vips: FAIL empty text"
      { line:, failed: !image.width.positive? }
    rescue StandardError => error
      { line: "vips: FAIL #{error.class}: #{error.message.to_s.truncate(160)}", failed: true }
    end

    def vips_cache
      require "vips"
      max = Vips.cache_max
      mem = Vips.cache_max_mem
      files = Vips.cache_max_files
      ok = max.zero? && mem.zero? && files.zero?
      detail = "max #{max} mem #{mem} files #{files}"
      { line: ok ? "vips-cache: #{detail}" : "vips-cache: FAIL #{detail}", failed: !ok }
    rescue StandardError => error
      { line: "vips-cache: FAIL #{error.class}: #{error.message.to_s.truncate(160)}", failed: true }
    end

    def inter
      require "vips"
      require "prawn"
      text = "Realty 0123456789"
      size = 40
      pango = Fonts.render(text, size:, weight: :regular).width
      prawn = prawn_width(text, size)
      close = (pango - prawn).abs <= (prawn * 0.03)
      detail = "pango #{pango} prawn #{prawn.round}"
      { line: close ? "inter: #{detail} within 3%" : "inter: FAIL #{detail}", failed: !close }
    rescue StandardError => error
      { line: "inter: FAIL #{error.class}: #{error.message.to_s.truncate(160)}", failed: true }
    end

    def devanagari
      require "vips"
      text = "सेठी रियल्टी"
      size = 40
      regular = Fonts.render(text, size:, weight: :regular).width
      semibold = Fonts.render(text, size:, weight: :semibold).width
      regular_face = explicit_devanagari(text, size, 400, :regular)
      semibold_face = explicit_devanagari(text, size, 600, :semibold)
      regular_ok = (regular - regular_face).abs <= (regular_face * 0.02)
      semibold_ok = (semibold - semibold_face).abs <= (semibold_face * 0.02)
      distinct = (semibold - regular).abs > (regular * 0.02)
      ok = regular_ok && semibold_ok && distinct
      detail = "regular #{regular}/#{regular_face} semibold #{semibold}/#{semibold_face}"
      { line: ok ? "devanagari: #{detail} within 2%" : "devanagari: FAIL #{detail}", failed: !ok }
    rescue StandardError => error
      { line: "devanagari: FAIL #{error.class}: #{error.message.to_s.truncate(160)}", failed: true }
    end

    def explicit_devanagari(text, size, weight, style)
      face = style == :semibold ? "Inter Semi-Bold" : "Inter"
      markup = %(<span font_family="Noto Sans Devanagari" font_weight="#{weight}">#{text}</span>)
      Vips::Image.text(markup, font: "#{face} #{size}", dpi: 72).width
    end

    def fc_scan
      if command?("fc-scan")
        { line: "fc-scan: present", failed: false }
      else
        { line: "fc-scan: absent (not needed)", failed: false }
      end
    end

    def preview
      if command?("pdftoppm")
        { line: "pdf-preview: pdftoppm", failed: false }
      elsif command?("mutool")
        { line: "pdf-preview: mutool", failed: false }
      else
        { line: "pdf-preview: warning, neither pdftoppm nor mutool", failed: false }
      end
    end

    def gems
      %w[combine_pdf prawn rqrcode mustache zip].each { |name| require name }
      { line: "gems: combine_pdf prawn rqrcode mustache rubyzip", failed: false }
    rescue StandardError => error
      { line: "gems: FAIL #{error.class}: #{error.message.to_s.truncate(160)}", failed: true }
    end

    def samples
      directory = Samples.doctor(@directory)
      jpg = directory.join("personalised.jpg")
      pdf = directory.join("personalised.pdf")
      ok = jpg.file? && pdf.file? && jpg.size.positive? && pdf.size.positive?
      { line: "samples: #{jpg} #{pdf}", failed: !ok }
    rescue StandardError => error
      { line: "samples: FAIL #{error.class}: #{error.message.to_s.truncate(160)}", failed: true }
    end

    def prawn_width(text, size)
      document = Prawn::Document.new
      document.font_families.update(
        "Inter" => { normal: Fonts.ttf(:regular), bold: Fonts.ttf(:semibold) }
      )
      document.font "Inter"
      document.width_of(text, size:)
    end

    def command?(name)
      system("which", name, out: File::NULL, err: File::NULL)
    end
  end
end
