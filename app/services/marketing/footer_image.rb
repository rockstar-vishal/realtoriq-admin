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
        logo_size:, measurer: method(:measure), heights: method(:measured_height)
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
      y = ((band.height - logo.height) / 2.0).round
      y = [ y, [ (2 * scale).round, 1 ].max ].max
      y = [ y, band.height - logo.height ].min
      band.composite2(logo, :over, x: (layout.pad * scale).round, y:)
    end

    def place_lines(band, layout, scale)
      rendered = layout.lines.map { |line| [ line, text_image(line, scale) ] }
      gap = [ (4 * scale).round, 1 ].max
      used = rendered.sum { |_, image| image.height + gap }
      y = [ ((band.height - used) / 2.0).round, [ (6 * scale).round, 1 ].max ].max
      placements = []
      rendered.each do |line, image|
        x = (layout.text_x * scale).round
        limit = band.width - image.width - [ (2 * scale).round, 1 ].max
        x = [ x, limit ].min if image.width + x > band.width
        x = [ x, 0 ].max
        band = band.composite2(image, :over, x:, y:)
        placements << Placement.new(
          text: line.text, x:, y:, width: image.width, height: image.height,
          size: (line.size * scale).round, weight: line.weight
        )
        y += image.height + gap
      end
      [ band, placements ]
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
