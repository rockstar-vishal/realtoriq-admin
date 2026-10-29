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

    def self.band(width:, firm:, project:, numbers:, logo_path: nil)
      new(nil, firm:, project:, numbers:, logo_path:).render_band(width)
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
      band = render_band(source.width)
      image = stack(source, band.image)
      Result.new(image:, lines: band.lines, band_height: band.band_height)
    end

    def render_band(width)
      Fonts.register!
      layout = FooterLayout.call(
        width:, firm: @firm, project: @project, numbers: @numbers,
        logo_size:, measurer: method(:measure)
      )
      image, placements = paint(layout)
      Band.new(
        image:, lines: layout.lines.map(&:text), band_height: layout.band_height,
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

    def paint(layout)
      band = Vips::Image.black(layout.width, layout.band_height).new_from_image([ 255, 255, 255, 255 ])
      band = band.copy(interpretation: :srgb)
      rule = Vips::Image.black(layout.width, 2).new_from_image([ 228, 228, 231, 255 ]).copy(interpretation: :srgb)
      band = band.composite2(rule, :over, x: 0, y: 0)
      band = place_logo(band, layout) if logo?
      place_lines(band, layout)
    end

    def place_logo(band, layout)
      logo = Vips::Image.new_from_file(@logo_path).autorot
      logo = logo.thumbnail_image(layout.logo_width, height: layout.logo_height, size: :down)
      logo = rgba(logo)
      y = ((layout.band_height - logo.height) / 2.0).round
      y = [ y, 2 ].max
      y = [ y, layout.band_height - logo.height ].min
      band.composite2(logo, :over, x: layout.pad, y:)
    end

    def place_lines(band, layout)
      rendered = layout.lines.map { |line| [ line, text_image(line) ] }
      used = rendered.sum { |_, image| image.height + 4 }
      y = [ (layout.band_height - used) / 2, 6 ].max
      placements = []
      rendered.each do |line, image|
        x = layout.text_x
        x = [ x, layout.width - image.width - 2 ].min if image.width + x > layout.width
        x = [ x, 0 ].max
        band = band.composite2(image, :over, x:, y:)
        placements << Placement.new(
          text: line.text, x:, y:, width: image.width, height: image.height,
          size: line.size, weight: line.weight
        )
        y += image.height + 4
      end
      [ band, placements ]
    end

    def text_image(line)
      mask = text_mask(line.text, line.size, line.weight)
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
