# frozen_string_literal: true

require "rails_helper"
require "vips"
require "prawn"
require "combine_pdf"

RSpec.describe "Marketing footer fonts and PDF bands" do
  let(:firm) { Marketing::Samples.firm("सेठी Realty") }
  let(:project) { Marketing::Samples.project }
  let(:numbers) { Marketing::Samples::NUMBERS }

  def stream_bodies(page)
    bodies = []
    walk = lambda do |obj, depth|
      return if obj.nil? || depth > 8

      case obj
      when Hash
        body = obj[:raw_stream_content]
        bodies << body if body.is_a?(String) && body.present?
        obj.each { |key, value| walk.call(value, depth + 1) unless key == :Parent }
      when Array
        obj.each { |value| walk.call(value, depth + 1) }
      end
    end
    walk.call(page[:Contents], 0)
    bodies.uniq
  end

  def box_values(raw)
    raw = raw[:referenced_object] while raw.is_a?(Hash) && raw[:referenced_object]
    Array(raw).map(&:to_f)
  end

  it "measures Inter the same way Pango and Prawn do" do
    text = "Realty 0123456789"
    size = 40
    pango = Marketing::Fonts.render(text, size:, weight: :regular).width
    document = Prawn::Document.new
    document.font_families.update(
      "Inter" => { normal: Marketing::Fonts.ttf(:regular), bold: Marketing::Fonts.ttf(:semibold) }
    )
    document.font "Inter"
    prawn = document.width_of(text, size:)
    expect((pango - prawn).abs).to be <= (prawn * 0.03)
  end

  it "draws a Devanagari name in SemiBold, not Regular" do
    text = "सेठी रियल्टी"
    size = 40
    semibold = Marketing::Fonts.render(text, size:, weight: :semibold).width
    explicit = Vips::Image.text(
      %(<span font_family="Noto Sans Devanagari" font_weight="600">#{text}</span>),
      font: "Inter Semi-Bold #{size}", dpi: 72
    ).width
    regular = Vips::Image.text(
      %(<span font_family="Noto Sans Devanagari" font_weight="400">#{text}</span>),
      font: "Inter #{size}", dpi: 72
    ).width
    expect((semibold - explicit).abs).to be <= (explicit * 0.02)
    expect((semibold - regular).abs).to be > (regular * 0.02)
  end

  it "renders a firm name that contains markup characters" do
    name = "Shah & Sons <Realty>"
    size = 40
    pango = Marketing::Fonts.render(name, size:, weight: :semibold).width
    document = Prawn::Document.new
    document.font_families.update(
      "Inter" => { normal: Marketing::Fonts.ttf(:regular), bold: Marketing::Fonts.ttf(:semibold) }
    )
    document.font "Inter", style: :bold
    prawn = document.width_of(name, size:)
    expect((pango - prawn).abs).to be <= (prawn * 0.03)

    named = Marketing::Samples.firm(name)
    file = Tempfile.new([ "creative", ".pdf" ])
    file.binmode
    file.write(Prawn::Document.new { |pdf| pdf.text "ORIGINAL-BODY" }.render)
    file.close
    rendered, lines = Marketing::FooterPdf.apply(file.path, firm: named, project:, numbers:)
    expect(lines.join(" ")).to include(name)
    out = Tempfile.new([ "out", ".pdf" ])
    out.binmode
    out.write(rendered)
    out.close
    text = IO.popen([ "pdftotext", "-layout", out.path, "-" ], &:read)
    expect(text).to include(name)
  end

  it "keeps the font names in line with fc-scan" do
    skip "fc-scan is not installed" unless system("which", "fc-scan", out: File::NULL, err: File::NULL)

    {
      Marketing::Fonts.ttf(:regular) => [ "Inter", "Regular", 80 ],
      Marketing::Fonts.ttf(:semibold) => [ "Inter", "SemiBold", 180 ],
      Marketing::Fonts.devanagari_ttf(:regular) => [ "Noto Sans Devanagari", "Regular", 80 ],
      Marketing::Fonts.devanagari_ttf(:semibold) => [ "Noto Sans Devanagari", "SemiBold", 180 ]
    }.each do |path, (family, style, weight)|
      expect(Marketing::Fonts.fc_scan(path)).to eq({ family:, style:, weight: })
    end
    expect(Marketing::Fonts::WEIGHTS).to eq(regular: 400, semibold: 600)
    expect(Marketing::Fonts::FC_WEIGHTS).to eq(regular: 80, semibold: 180)
  end

  it "puts the agent and project registration numbers on their own lines" do
    layout = Marketing::FooterLayout.call(
      width: 1400, firm:, project:, numbers:, logo_size: nil,
      measurer: ->(text, _size, _weight) { text.length * 8 }
    )
    expect(layout.lines.map(&:text)).to include(
      "MahaRERA Agent Reg. No. A51900000001",
      "Project Reg. No. P51800000001, P51800000002"
    )
  end

  it "starts the text one pad after the drawn logo" do
    layout = Marketing::FooterLayout.call(
      width: 1400, firm:, project:, numbers:, logo_size: [ 64, 64 ],
      measurer: ->(*) { 20 }
    )
    expect(layout.drawn_width).to eq(64)
    expect(layout.drawn_height).to eq(64)
    expect(layout.text_x).to eq(layout.pad + layout.drawn_width + layout.pad)
  end

  it "gives a wide wordmark twice the logo height" do
    layout = Marketing::FooterLayout.call(
      width: 1400, firm:, project:, numbers:, logo_size: [ 600, 200 ],
      measurer: ->(*) { 20 }
    )
    expect(layout.drawn_width).to be_within(2).of(236)
    expect(layout.drawn_height).to be_within(2).of(79)
    expect(layout.text_x).to eq(layout.pad + layout.drawn_width + layout.pad)
  end

  it "turns a phone-shot creative upright before the footer is added" do
    image = Vips::Image.black(80, 30).new_from_image([ 10, 20, 200 ]).copy(interpretation: :srgb)
    image = image.mutate { |mutable| mutable.set_type!(GObject::GINT_TYPE, "orientation", 6) }
    prepared = Marketing::FooterImage.prepare(image)
    expect(prepared.width).to eq(30)
    expect(prepared.height).to eq(80)
  end

  it "keeps the original PDF stream and draws the band as an image" do
    bytes = Prawn::Document.new(page_size: [ 500, 400 ], margin: 36) do |pdf|
      pdf.text "ORIGINAL-BODY"
      pdf.start_new_page
      pdf.text "ORIGINAL-BODY"
    end.render
    file = Tempfile.new([ "creative", ".pdf" ])
    file.binmode
    file.write(bytes)
    file.close
    original = CombinePDF.parse(bytes).pages.map { |page| stream_bodies(page) }

    rendered, lines = Marketing::FooterPdf.apply(file.path, firm:, project:, numbers:)
    expect(lines.join(" ")).to include(firm.name, "A51900000001", "P51800000001")
    pdf = CombinePDF.parse(rendered)
    expect(pdf.pages.size).to eq(2)
    out = Tempfile.new([ "out", ".pdf" ])
    out.binmode
    out.write(rendered)
    out.close
    text = IO.popen([ "pdftotext", "-layout", out.path, "-" ], &:read)
    expect(text).to include("सेठी", "A51900000001", "P51800000001", "P51800000002", "ORIGINAL-BODY")
    pdf.pages.each_with_index do |page, index|
      expect(image_on_page?(page)).to be(true)
      original[index].each { |body| expect(stream_bodies(page)).to include(body) }
    end
  end

  it "anchors the band to the crop box and covers the bleed" do
    file = Tempfile.new([ "bleed", ".pdf" ])
    file.binmode
    file.write(Marketing::Samples.bleed_pdf)
    file.close
    before = stream_bodies(CombinePDF.parse(File.binread(file.path)).pages.first)

    rendered, = Marketing::FooterPdf.apply(file.path, firm:, project:, numbers:)
    page = CombinePDF.parse(rendered).pages.first
    band = Marketing::FooterImage.band(width: (596 * 4), firm:, project:, numbers:)
    band_pt = band.band_height / 4.0
    crop = box_values(page[:CropBox])
    media = box_values(page[:MediaBox])
    expect(crop[0]).to be_within(0.05).of(12)
    expect(crop[2]).to be_within(0.05).of(608)
    expect(crop[1]).to be_within(0.05).of(12 - band_pt)
    expect(crop[3]).to be_within(0.05).of(848)
    expect(media[0]).to be_within(0.05).of(0)
    expect(media[1]).to be_within(0.05).of(12 - band_pt)
    expect(media[2]).to be_within(0.05).of(620)
    expect(media[3]).to be_within(0.05).of(860)
    %i[BleedBox TrimBox ArtBox].each do |name|
      values = box_values(page[name])
      expect(values[0]).to be_within(0.05).of(12)
      expect(values[1]).to be_within(0.05).of(12 - band_pt)
      expect(values[2]).to be_within(0.05).of(608)
      expect(values[3]).to be_within(0.05).of(848)
    end
    expect(stream_bodies(page)).to include(*before)

    next unless system("which pdftoppm >/dev/null 2>&1")

    Dir.mktmpdir do |dir|
      out = File.join(dir, "page.pdf")
      File.binwrite(out, rendered)
      system("pdftoppm", "-png", "-r", "72", "-cropbox", out, File.join(dir, "page"))
      image = Vips::Image.new_from_file(File.join(dir, "page-1.png"))
      expect(image.width).to eq(596)
      band_rows = image.height - (848 - 12)
      expect(band_rows).to be > 20
      column = image.width - 4
      band_rows.times do |offset|
        pixel = image.getpoint(column, image.height - 1 - offset)
        expect(pixel[0]).to be > 200
      end
      above = image.getpoint(column, image.height - band_rows - 1)
      expect(above[0]).to be < 40
    end
  end

  def image_on_page?(page)
    found = false
    walk = lambda do |obj, depth|
      return if found || obj.nil? || depth > 8

      case obj
      when Hash
        found = true if obj[:Subtype] == :Image
        obj.each { |key, value| walk.call(value, depth + 1) unless key == :Parent }
      when Array
        obj.each { |value| walk.call(value, depth + 1) }
      end
    end
    walk.call(page[:Resources], 0)
    found
  end
end
