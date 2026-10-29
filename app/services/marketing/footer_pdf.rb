# frozen_string_literal: true

require "combine_pdf"
require "prawn"

module Marketing
  # Adds the same band under every page. The visible page (the crop box, or
  # the media box when there is no crop) grows downward. The original content
  # stream is left as it was. The band is the image footer, with an invisible
  # text layer so the words can be copied.
  class FooterPdf
    SCALE = 4
    BOXES = %i[CropBox BleedBox TrimBox ArtBox].freeze

    def self.apply(path, firm:, project:, numbers:, logo_path: nil)
      new(path, firm:, project:, numbers:, logo_path:).apply
    end

    def initialize(path, firm:, project:, numbers:, logo_path:)
      @path = path
      @firm = firm
      @project = project
      @numbers = numbers
      @logo_path = logo_path
    end

    def apply
      pdf = CombinePDF.parse(File.binread(@path))
      lines = []
      pdf.pages.each do |page|
        page.fix_rotation if page[:Rotate].to_i != 0
        visible = visible_box(page)
        width = (visible[2] - visible[0]).abs
        band = FooterImage.band(
          width: (width * SCALE).round, firm: @firm, project: @project,
          numbers: @numbers, logo_path: @logo_path
        )
        band_pt = band.band_height / SCALE.to_f
        lines = band.lines
        extend_boxes(page, visible, band_pt)
        page << stamp(band, width, band_pt, visible[0], visible[1] - band_pt)
      end
      [ pdf.to_pdf, lines ]
    end

    private

    def visible_box(page)
      media = box_of(page, :MediaBox)
      crop = page[:CropBox] ? box_of(page, :CropBox) : media
      intersect(crop, media) || media
    end

    def box_of(page, name)
      raw = page[name]
      raw = raw[:referenced_object] while raw.is_a?(Hash) && raw[:referenced_object]
      Array(raw).map(&:to_f)
    end

    def intersect(crop, media)
      llx = [ crop[0], media[0] ].max
      lly = [ crop[1], media[1] ].max
      urx = [ crop[2], media[2] ].min
      ury = [ crop[3], media[3] ].min
      return if urx <= llx || ury <= lly

      [ llx, lly, urx, ury ]
    end

    def extend_boxes(page, visible, band_pt)
      extended = [ visible[0], visible[1] - band_pt, visible[2], visible[3] ]
      media = box_of(page, :MediaBox)
      page[:MediaBox] = [
        [ media[0], extended[0] ].min,
        [ media[1], extended[1] ].min,
        [ media[2], extended[2] ].max,
        [ media[3], extended[3] ].max
      ]
      BOXES.each { |name| page[name] = extended }
    end

    def stamp(band, width, band_pt, origin_x, origin_y)
      bytes = band_pdf(band, width, band_pt)
      page = CombinePDF.parse(bytes).pages.first
      # insert_content is how CombinePDF itself builds a content stream. It is
      # protected, and there is no public offset for a stamp.
      page.send(:insert_content, format("q\n1 0 0 1 %.3f %.3f cm\n", origin_x, origin_y), 0)
      page.send(:insert_content, "\nQ\n")
      page
    end

    def band_pdf(band, width, band_pt)
      Tempfile.create([ "band", ".png" ]) do |file|
        opaque(band.image).write_to_file(file.path)
        Prawn::Document.new(page_size: [ width, band_pt ], margin: 0) do |pdf|
          register(pdf)
          pdf.image file.path, at: [ 0, band_pt ], width:, height: band_pt
          band.placements.each { |placement| draw_invisible(pdf, placement, width, band_pt) }
        end.render
      end
    end

    def draw_invisible(pdf, placement, width, band_pt)
      size = placement.size / SCALE.to_f
      x = placement.x / SCALE.to_f
      top = band_pt - (placement.y / SCALE.to_f)
      style = placement.weight == :semibold ? :bold : :normal
      pdf.font "Inter", style: style
      pdf.text_rendering_mode(:invisible) do
        pdf.text_box(
          placement.text,
          at: [ x, top ],
          width: [ width - x, size ].max,
          height: [ (placement.height / SCALE.to_f) + size, size * 2 ].max,
          size:,
          overflow: :expand,
          fallback_fonts: [ "NotoSansDevanagari" ]
        )
      end
    end

    def opaque(image)
      image = image.flatten(background: [ 255, 255, 255 ]) if image.has_alpha?
      image = image.colourspace(:srgb) unless image.interpretation == :srgb
      image.bands > 3 ? image.extract_band(0, n: 3) : image
    end

    def register(pdf)
      pdf.font_families.update(
        "Inter" => { normal: Fonts.ttf(:regular), bold: Fonts.ttf(:semibold) },
        "NotoSansDevanagari" => {
          normal: Fonts.devanagari_ttf(:regular),
          bold: Fonts.devanagari_ttf(:semibold)
        }
      )
      pdf.fallback_fonts [ "NotoSansDevanagari" ]
    end
  end
end
