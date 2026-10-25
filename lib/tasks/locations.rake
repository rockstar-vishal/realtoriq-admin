# frozen_string_literal: true

namespace :locations do
  desc "List properties and own projects that have no map pin"
  task missing: :environment do
    Current.set(firm_scope_bypassed: true) do
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

      approximate_properties = Property.across_firms.includes(:firm).where(pin_approximate: true).to_a
      approximate_projects = Project.across_firms.includes(:firm).where(source: "own", pin_approximate: true).to_a
      puts "approximate"
      approximate_properties.each { |property| puts LocationsRake.listing_line(property, property.title, "property") }
      approximate_projects.each { |project| puts LocationsRake.listing_line(project, project.name, "project") }
      puts "approximate\t#{approximate_properties.size + approximate_projects.size}"
    end
  end

  desc "Put each unpinned listing on its locality centre and mark it approximate. DRY_RUN=1 by default; DRY_RUN=0 writes."
  task approximate_pins: :environment do
    Current.set(firm_scope_bypassed: true) do
      dry_run = ENV["DRY_RUN"] != "0"
      placed = 0
      skipped = []

      LocationsRake.each_unpinned_listing do |record|
        centre = LocationsRake.locality_centre(record)
        if centre.nil?
          skipped << record
          next
        end

        unless dry_run
          record.update_columns(lat: centre[0], lng: centre[1], pin_approximate: true)
        end
        placed += 1
      end

      puts "#{dry_run ? "would set" : "set"}\t#{placed}"
      skipped.each do |record|
        title = record.is_a?(Property) ? record.title : record.name
        puts "#{record.code}\t#{title}"
      end
    end
  end

  desc "Clear pins that were placed at the locality centre. DRY_RUN=1 by default; DRY_RUN=0 writes."
  task clear_approximate_pins: :environment do
    Current.set(firm_scope_bypassed: true) do
      dry_run = ENV["DRY_RUN"] != "0"
      rows = Property.across_firms.where(pin_approximate: true).to_a
      rows += Project.across_firms.where(pin_approximate: true).to_a
      unless dry_run
        rows.each { |record| record.update_columns(lat: nil, lng: nil, pin_approximate: false) }
      end
      puts "#{dry_run ? "would clear" : "cleared"}\t#{rows.size}"
    end
  end
end

module LocationsRake
  module_function

  def listing_line(record, title, kind)
    [ record.firm&.name, record.code, title, kind ].join("\t")
  end

  def each_unpinned_listing
    Property.across_firms.includes(:locality).where("lat IS NULL OR lng IS NULL").find_each { |row| yield row }
    Project.across_firms.includes(:locality).where(source: "own").where("lat IS NULL OR lng IS NULL").find_each { |row| yield row }
  end

  def locality_centre(record)
    locality = record.locality
    return if locality.nil? || locality.lat.blank? || locality.lng.blank?

    [ locality.lat, locality.lng ]
  end
end
