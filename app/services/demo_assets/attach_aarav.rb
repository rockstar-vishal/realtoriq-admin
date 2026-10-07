# frozen_string_literal: true

module DemoAssets
  # Attaches Aarav Realty's project photos, listing photos, and brokerage
  # ladders from the demo_assets folder. Checks every row first, then writes,
  # so a missing listing does not wipe a project that already matched.
  class AttachAarav
    PROJECTS = {
      "Palm Court Residences" => {
        photos: %w[palm-court-andheri-1.jpg palm-court-andheri-2.jpg],
        ladder: "palm-court-andheri-ladder.png"
      },
      "Sahyadri Enclave" => {
        photos: %w[sahyadri-enclave-kharghar-1.jpg sahyadri-enclave-kharghar-2.jpg],
        ladder: "sahyadri-enclave-kharghar-ladder.png"
      }
    }.freeze

    LISTINGS = {
      "resale-andheri-west-2bhk.jpg" => { listing_for: "sale", locality: "Andheri West", typology: "2 BHK", price: 18_000_000 },
      "resale-powai-3bhk.jpg" => { listing_for: "sale", locality: "Powai", typology: "3 BHK", price: 31_000_000 },
      "resale-kharghar-2bhk.jpg" => { listing_for: "sale", locality: "Kharghar", typology: "2 BHK", price: 9_500_000 },
      "resale-goregaon-west-2bhk.jpg" => { listing_for: "sale", locality: "Goregaon West", typology: "2 BHK", price: 16_000_000 },
      "rent-andheri-west-2bhk.jpg" => { listing_for: "rent", locality: "Andheri West", typology: "2 BHK", price: 75_000 },
      "rent-powai-2bhk.jpg" => { listing_for: "rent", locality: "Powai", typology: "2 BHK", price: 85_000 },
      "rent-thane-2bhk.jpg" => { listing_for: "rent", locality: "Thane", typology: "2 BHK", price: 42_000 }
    }.freeze

    def self.call(dir:, firm:, projects: PROJECTS, listings: LISTINGS)
      new(dir:, firm:, projects:, listings:).call
    end

    def initialize(dir:, firm:, projects:, listings:)
      @dir = Pathname(dir)
      @firm = firm
      @projects = projects
      @listings = listings
    end

    def call
      Current.set(firm:) do
        planned_projects = projects.map { |name, files| [ firm.projects.find_by!(name:), files ] }
        planned_listings = listings.map { |file, spec| [ find_listing!(file, spec), dir.join(file) ] }
        planned_projects.each { |project, files| attach_project(project, files) }
        planned_listings.each { |property, file| attach_listing(property, file) }
      end
    end

    private

    attr_reader :dir, :firm, :projects, :listings

    def attach_project(project, files)
      photos = files[:photos].map { |file| dir.join(file) }
      ladder = dir.join(files[:ladder])
      photos.each { |file| raise "missing #{file}" unless file.file? }
      raise "missing #{ladder}" unless ladder.file?

      attach_ordered(project, photos, "image/jpeg")
      File.open(ladder) do |io|
        project.brokerage_ladder.attach(io:, filename: ladder.basename.to_s, content_type: "image/png")
      end
      puts "#{project.name} photos=#{project.photos.count} ladder=#{project.brokerage_ladder.attached?}"
    end

    def attach_listing(property, file)
      raise "missing #{file}" unless file.file?

      attach_ordered(property, [ file ], "image/jpeg")
      puts "#{property.listing_for} #{property.typology.name} #{property.building.locality.name} #{property.price} photos=#{property.photos.count}"
    end

    def find_listing!(file, spec)
      locality = Locality.joins(:city).find_by!(name: spec[:locality], cities: { name: "Mumbai" })
      matches = firm.properties.joins(:building, :typology).where(
        listing_for: spec[:listing_for], price: spec[:price],
        buildings: { locality_id: locality.id }, typologies: { name: spec[:typology] }
      ).to_a
      raise "expected one #{file}, found #{matches.size}" unless matches.one?

      matches.first
    end

    def attach_ordered(record, files, content_type)
      record.photos.purge
      files.each do |file|
        File.open(file) do |io|
          blob = ActiveStorage::Blob.create_and_upload!(
            io:, filename: file.basename.to_s, content_type:
          )
          ActiveStorage::Attachment.create!(
            id: UuidV7.generate, name: "photos", record:, blob:
          )
        end
      end
    end
  end
end
