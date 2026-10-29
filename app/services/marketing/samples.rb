# frozen_string_literal: true

require "fileutils"

module Marketing
  # Sample creatives with no database rows. The doctor and the review files
  # both use this.
  class Samples
    Channel = Struct.new(:kind, :value) do
      def verified? = true
    end
    FirmCard = Struct.new(:name, :rera_number, :contact_channels)
    CityCard = Struct.new(:state)
    ProjectCard = Struct.new(:city, :name)
    NUMBERS = %w[P51800000001 P51800000002].freeze

    def self.firm(name)
      FirmCard.new(
        name,
        "A51900000001",
        [
          Channel.new("mobile", "+919820155001"),
          Channel.new("whatsapp", "+919820155001")
        ]
      )
    end

    def self.project
      ProjectCard.new(CityCard.new("Maharashtra"), "Harbour One")
    end

    def self.doctor(directory)
      directory = Pathname(directory)
      FileUtils.mkdir_p(directory)
      firm = firm("सेठी Realty")
      write_jpeg(directory.join("personalised.jpg"), firm, square_logo)
      write_pdf(directory.join("personalised.pdf"), firm, square_logo, a4_pdf)
      directory
    end

    def self.review(directory)
      directory = Pathname(directory)
      FileUtils.mkdir_p(directory)
      write_jpeg(directory.join("personalised.jpg"), firm("सेठी Realty"), square_logo, width: 1080, height: 1350)
      write_jpeg(
        directory.join("personalised-landscape.jpg"), firm("सेठी Realty"), square_logo, width: 1200, height: 628
      )
      write_jpeg(
        directory.join("personalised-wide-logo.jpg"),
        firm("Aarav Realty and Property Consultants LLP"),
        wide_logo
      )
      write_jpeg(directory.join("personalised-ampersand.jpg"), firm("Shah & Sons <Realty>"), square_logo)
      write_pdf(directory.join("personalised.pdf"), firm("सेठी Realty"), square_logo, a4_pdf)
      directory
    end

    def self.write_jpeg(path, firm, logo_bytes, width: 1400, height: 900)
      with_files(artwork(width, height), logo_bytes) do |artwork, logo|
        composed = FooterImage.compose(
          artwork, firm:, project:, numbers: NUMBERS, logo_path: logo
        )
        image = composed.image
        image = image.flatten(background: [ 255, 255, 255 ]) if image.has_alpha?
        image.write_to_file(path.to_s, Q: 88, strip: true)
      end
    end

    def self.write_pdf(path, firm, logo_bytes, pdf_bytes)
      with_files(pdf_bytes, logo_bytes, artwork_ext: ".pdf") do |artwork, logo|
        rendered, = FooterPdf.apply(artwork, firm:, project:, numbers: NUMBERS, logo_path: logo)
        File.binwrite(path, rendered)
      end
    end

    def self.with_files(artwork_bytes, logo_bytes, artwork_ext: ".png")
      artwork = Tempfile.new([ "artwork", artwork_ext ])
      logo = Tempfile.new([ "logo", ".png" ])
      artwork.binmode
      logo.binmode
      artwork.write(artwork_bytes)
      logo.write(logo_bytes)
      artwork.flush
      logo.flush
      yield artwork.path, logo.path
    ensure
      artwork&.close!
      logo&.close!
    end

    def self.artwork(width, height)
      Vips::Image.black(width, height).new_from_image([ 18, 42, 84 ]).copy(interpretation: :srgb).write_to_buffer(".png")
    end

    def self.artwork_png
      artwork(1400, 900)
    end

    def self.square_logo
      Vips::Image.black(128, 128).new_from_image([ 20, 40, 180 ]).copy(interpretation: :srgb).write_to_buffer(".png")
    end

    def self.wide_logo
      Vips::Image.black(600, 200).new_from_image([ 20, 40, 180 ]).copy(interpretation: :srgb).write_to_buffer(".png")
    end

    def self.a4_pdf
      Prawn::Document.new(page_size: "A4", margin: 48) { |pdf| pdf.text "Sample creative" }.render
    end

    def self.bleed_pdf
      bytes = Prawn::Document.new(page_size: [ 620, 860 ], margin: 0) do |pdf|
        pdf.fill_color "000000"
        pdf.fill_rectangle [ 0, 860 ], 620, 860
      end.render
      pdf = CombinePDF.parse(bytes)
      pdf.pages.first[:CropBox] = [ 12, 12, 608, 848 ]
      pdf.to_pdf
    end
  end
end
