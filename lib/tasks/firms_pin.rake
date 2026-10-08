# frozen_string_literal: true

namespace :firms do
  desc "Set a primary city and locality on the known firms when they have none"
  task pin: :environment do
    # The four firms this install is expected to have. Pins match the demo
    # portal and the review-demo task. A pin already stored is left alone.
    pins = {
      "Aarav Realty" => "Andheri West",
      "Kapoor Estates" => "Powai",
      "Deshmukh Properties" => "Kharghar",
      "RealtorIQ Demo" => "Kharghar"
    }

    city = City.find_by(name: "Mumbai", state: "Maharashtra")
    abort("Mumbai is not in the locality masters. Nothing was changed.") if city.nil?

    firms = Firm.order(:name).to_a
    unknown = firms.select { |firm| firm.city_id.blank? || firm.locality_id.blank? }
      .reject { |firm| pins.key?(firm.name) }
    if unknown.any?
      abort("No pin mapped for #{unknown.map(&:name).join(', ')}. Nothing was changed.")
    end

    needed = pins.filter_map do |name, locality_name|
      firm = firms.find { |row| row.name == name }
      next if firm.nil? || (firm.city_id.present? && firm.locality_id.present?)

      locality = Locality.find_by(city:, name: locality_name)
      abort("Missing locality #{locality_name}. Nothing was changed.") if locality.nil?

      [ firm, locality ]
    end

    Firm.transaction do
      needed.each do |firm, locality|
        firm.update!(city:, locality:)
        puts "Pin #{firm.name}: Mumbai / #{locality.name}"
      end
    end

    pins.each_key do |name|
      firm = firms.find { |row| row.name == name }
      if firm.nil?
        puts "Skip #{name}: not in this database"
      elsif needed.none? { |row, _locality| row.id == firm.id }
        puts "Keep #{firm.name}: #{firm.city.name} / #{firm.locality.name}"
      end
    end
  end
end
