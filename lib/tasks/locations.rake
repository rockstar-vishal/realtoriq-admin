# frozen_string_literal: true

namespace :locations do
  desc "List properties and own projects that have no map pin"
  task missing: :environment do
    properties = Property.across_firms.includes(:firm, :typology, :locality).select { |row| !row.has_pin? }
    projects = Project.across_firms.includes(:firm).where(source: "own").select { |row| !row.has_pin? }

    properties.each do |property|
      puts [ property.firm&.name, property.code, property.title, "property" ].join("\t")
    end
    projects.each do |project|
      puts [ project.firm&.name, project.code, project.name, "project" ].join("\t")
    end
    puts "properties\t#{properties.size}"
    puts "projects\t#{projects.size}"
    puts "total\t#{properties.size + projects.size}"
  end

  desc "Copy a placed pin to other properties of the same old building. DRY_RUN=1 prints only."
  task copy_to_siblings: :environment do
    dry_run = ENV["DRY_RUN"] == "1"
    Property.across_firms.where.not(building_id: nil).where.not(lat: nil, lng: nil).find_each do |source|
      Property.across_firms.where(building_id: source.building_id, lat: nil, lng: nil).where.not(id: source.id).find_each do |target|
        puts "#{source.code}\t#{target.code}\t#{source.lat}\t#{source.lng}"
        next if dry_run

        target.update_columns(
          address: source.address,
          lat: source.lat,
          lng: source.lng,
          google_place_id: source.google_place_id,
          updated_at: Time.current
        )
      end
    end
  end
end
