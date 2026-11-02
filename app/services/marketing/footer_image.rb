# frozen_string_literal: true

require "vips"

module Marketing
  # Draws the footer under the artwork. The artwork is not scaled below its
  # own size, and nothing is painted over it. PDFs use the same band.
  class FooterImage
    Result = Data.define(:image, :lines, :band_height)
    Band = Data.define(:image, :lines, :band_height, :placements, :layout)
    Placement = Data.define(:text, :x, :y, :width, :height, :size, :weight)
    MAX_WIDTH = 2160

    def self.compose(path, firm:, project:, numbers:, logo_path: nil)
      new(path, firm:, project:, numbers:, logo_path:).compose
    end

    def self.band(width:, height:, firm:, project:, numbers:, logo_path: nil, scale: 1)
      new(nil, firm:, project:, numbers:, logo_path:).render_band(width, height, scale)
    end

    def self.prepare(image)
      image = image.autorot
      return image if image.width <= MAX_WIDTH

      image.thumbnail_image(MAX_WIDTH, height: image.height, size: :down)
    end

    def initialize(path, firm:, project:, numbers:, logo_path:)
      @path = path
      @firm = firm
      @project = project
      @numbers = numbers
      @logo_path = logo_path
    end

    def compose
      source = self.class.prepare(Vips::Image.new_from_file(@path))
      band = render_band(source.width, source.height, 1)
      image = stack(source, band.image)
      Result.new(image:, lines: band.lines, band_height: band.band_height)
    end

    def render_band(width, height, scale)
      Fonts.register!
      layout = FooterLayout.call(
        width:, height:, firm: @firm, project: @project, numbers: @numbers,
        logo_size:, measurer: method(:measure), heights: method(:measured_height),
        line_measurer: method(:measure_runs)
      )
      image, placements = paint(layout, scale)
      Band.new(
        image:, lines: layout.lines.map(&:text),
        band_height: (layout.band_height * scale).round,
        placements:, layout:
      )
    end

    private

    def logo?
      @logo_path.present? && File.exist?(@logo_path.to_s)
    end

    def logo_size
      return unless logo?

      image = Vips::Image.new_from_file(@logo_path).autorot
      [ image.width, image.height ]
    end

    def measure(text, size, weight)
      text_mask(text, size, weight).width
    end

    def measure_runs(runs, size)
      Fonts.render_runs(runs, size:).width
    end

    def measured_height(text, size, weight)
      text_mask(text, size, weight).height
    end

    def paint(layout, scale)
      width = (layout.width * scale).round
      height = (layout.band_height * scale).round
      band = Vips::Image.black(width, height).new_from_image([ 255, 255, 255, 255 ])
      band = band.copy(interpretation: :srgb)
      rule = Vips::Image.black(width, [ (2 * scale).round, 1 ].max).new_from_image([ 228, 228, 231, 255 ])
      rule = rule.copy(interpretation: :srgb)
      band = band.composite2(rule, :over, x: 0, y: 0)
      band = place_logo(band, layout, scale) if logo?
      place_lines(band, layout, scale)
    end

    def place_logo(band, layout, scale)
      logo = Vips::Image.new_from_file(@logo_path).autorot
      box_w = (layout.logo_width * scale).round
      box_h = (layout.logo_height * scale).round
      logo = logo.thumbnail_image(box_w, height: box_h, size: :down)
      logo = rgba(logo)
      text_top = (layout.pad_y * scale).round
      row1 = (layout.row1_height * scale).round
      y = text_top + ((row1 - logo.height) / 2.0).round
      y = [ y, [ (2 * scale).round, 1 ].max ].max
      y = [ y, band.height - logo.height ].min
      band.composite2(logo, :over, x: (layout.pad * scale).round, y:)
    end

    def place_lines(band, layout, scale)
      placements = []
      y = (layout.pad_y * scale).round
      names = layout.lines.select { |line| line.group == :name }
      call = layout.lines.find { |line| line.group == :call }
      regs = layout.lines.select { |line| line.group == :registration }
      contact = names + [ call ].compact
      row1 = (layout.row1_height * scale).round
      if call&.align == :right
        band, = place_row(band, layout, contact, y, scale, placements, row_h: row1)
      else
        band = place_stack(band, layout, names, call, y, row1, scale, placements)
      end
      y += row1
      y += (layout.gap * scale).round if regs.any? && contact.any?
      regs.each { |line| band, y = place_line(band, layout, line, y, scale, placements) }
      [ band, placements ]
    end

    def place_stack(band, layout, names, call, y0, row1, scale, placements)
      gap = names.any? && call ? (layout.stack_gap * scale).round : 0
      text_h = names.sum { |line| (line.box * scale).round } + gap + (call ? (call.box * scale).round : 0)
      y = y0 + [ ((row1 - text_h) / 2.0).round, 0 ].max
      names.each { |line| band, y = place_line(band, layout, line, y, scale, placements) }
      y += gap
      band, = place_line(band, layout, call, y, scale, placements) if call
      band
    end

    def place_row(band, layout, lines, y, scale, placements, row_h:)
      rendered = lines.map { |line| [ line, render_line(line, scale) ] }
      row_h = [ row_h, rendered.map { |_, image| image.height }.max ].max
      rendered.each do |line, image|
        x = line_x(band, layout, line, image, scale)
        glyph_y = y + ((row_h - image.height) / 2.0).round
        band = band.composite2(image, :over, x:, y: glyph_y)
        placements << placement_for(line, image, x, glyph_y, scale)
      end
      [ band, y + row_h ]
    end

    def place_line(band, layout, line, y, scale, placements)
      image = render_line(line, scale)
      box = [ (line.box * scale).round, image.height ].max
      x = line_x(band, layout, line, image, scale)
      glyph_y = y + ((box - image.height) / 2.0).round
      band = band.composite2(image, :over, x:, y: glyph_y)
      placements << placement_for(line, image, x, glyph_y, scale)
      [ band, y + box ]
    end

    def line_x(band, layout, line, image, scale)
      if line.align == :right
        [ band.width - (layout.pad * scale).round - image.width, 0 ].max
      else
        origin = line.group == :registration ? layout.pad : layout.text_x
        (origin * scale).round
      end
    end

    def placement_for(line, image, x, y, scale)
      Placement.new(
        text: line.text, x:, y:, width: image.width, height: image.height,
        size: (line.size * scale).round, weight: line.weight
      )
    end

    def render_line(line, scale)
      size = [ (line.size * scale).round, 1 ].max
      return Fonts.render_runs(line.runs, size:) if line.runs.length > 1

      text_image(line, scale)
    end

    def text_image(line, scale)
      mask = text_mask(line.text, (line.size * scale).round, line.weight)
      rgb = mask.new_from_image(rgb(line.color)).copy(interpretation: :srgb)
      rgba(rgb.bandjoin(mask))
    end

    def text_mask(text, size, weight)
      Fonts.render(text, size:, weight:)
    end

    def stack(source, band)
      if source.has_alpha?
        source = rgba(source)
        band = rgba(band)
      else
        source = rgb_image(source)
        band = band.flatten(background: [ 255, 255, 255 ])
        band = rgb_image(band)
      end
      source.join(band, :vertical)
    end

    def rgba(image)
      image = image.colourspace(:srgb) unless image.interpretation == :srgb
      image = image.bandjoin(255) unless image.has_alpha?
      image.extract_band(0, n: 4)
    end

    def rgb_image(image)
      image = image.flatten(background: [ 255, 255, 255 ]) if image.has_alpha?
      image = image.colourspace(:srgb) unless image.interpretation == :srgb
      image.bands > 3 ? image.extract_band(0, n: 3) : image
    end

    def rgb(hex)
      [ hex[0, 2].to_i(16), hex[2, 2].to_i(16), hex[4, 2].to_i(16) ]
    end
  end
end
