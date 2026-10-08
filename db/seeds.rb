# frozen_string_literal: true

# Reference data only — the dropdowns and plans every firm depends on. Safe to
# run in any environment, and idempotent, so re-running it after adding a city
# or a plan updates rather than duplicates.
#
# Deliberately absent:
#   - admin users  → `bin/rails admin:create`, so no known credential exists
#   - demo firms   → `bin/rails demo:seed`, which refuses to run in production
#
# Values come from the product design, so the broker app's dropdowns match what
# was designed rather than being invented here.

puts "Seeding masters…"

# MMR plus Pune and Nashik — the market the product was designed around. Ops can
# add more from Masters → Cities without a deploy.
#
# KEEP IN SYNC with turbo (turbo-rails8/migration/consolidate_locations.rb): turbo pushes
# project city/locality NAMES here, so both products must use the same list. Thane,
# Palghar and Navi Mumbai areas are localities of Mumbai (a region layer comes later).
#
# A local rather than a constant: seeds.rb is loaded, not required, so a constant
# here would both pollute Object and warn on every reload.
cities_by_state = {
  "Maharashtra" => [
    [ "Mumbai", [
      "Colaba", "Cuffe Parade", "Nariman Point", "Churchgate", "Fort", "Marine Lines",
      "Girgaon", "Grant Road", "Malabar Hill", "Napean Sea Road", "Peddar Road", "Breach Candy",
      "Tardeo", "Mumbai Central", "Mahalaxmi", "Byculla", "Mazgaon", "Worli",
      "Lower Parel", "Parel", "Sewri", "Wadala", "Prabhadevi", "Dadar East",
      "Dadar West", "Mahim", "Matunga", "Sion", "Bandra East", "Bandra West",
      "BKC", "Khar East", "Khar West", "Santacruz East", "Santacruz West", "Vile Parle East", "Vile Parle West",
      "Juhu", "Andheri East", "Andheri West", "Jogeshwari East", "Jogeshwari West", "Goregaon East",
      "Goregaon West", "Malad East", "Malad West", "Kandivali East", "Kandivali West", "Borivali East",
      "Borivali West", "Dahisar East", "Dahisar West", "Kurla East", "Kurla West", "Chembur",
      "Govandi", "Mankhurd", "Ghatkopar East", "Ghatkopar West", "Vidyavihar", "Powai",
      "Chandivali", "Vikhroli East", "Vikhroli West", "Kanjurmarg East", "Kanjurmarg West", "Bhandup East",
      "Bhandup West", "Mulund East", "Mulund West", "Thane", "Kalyan", "Dombivli",
      "Mira Road", "Bhayandar", "Bhiwandi", "Ulhasnagar", "Ambernath", "Badlapur",
      "Palghar", "Vasai", "Nalasopara", "Virar", "Boisar", "Airoli",
      "Ghansoli", "Kopar Khairane", "Vashi", "Sanpada", "Nerul", "Seawoods",
      "CBD Belapur", "Kharghar", "Kamothe", "Kalamboli", "Panvel", "New Panvel",
      "Ulwe", "Taloja", "Dronagiri"
    ] ],
    [ "Pune", [
      "Wakad", "Baner", "Balewadi", "Hinjewadi", "Tathawade", "Punawale",
      "Pashan", "Sus", "Bavdhan", "Pimple Saudagar", "Pimple Gurav", "Aundh",
      "Kharadi", "Wagholi", "Dhanori", "Mahalunge", "Warje", "Bibwewadi",
      "Chinchwad", "Rahatani", "Marunji", "Bhugaon", "Hadapsar", "Mundhwa",
      "Bund Garden", "Wakdewadi", "Kiwale", "NIBM", "Vishal Nagar", "Moshi",
      "Charholi", "Manchar", "Alephata", "Kothrud"
    ] ],
    [ "Nashik", [
      "Gangapur Road", "Indira Nagar", "Panchavati"
    ] ]
  ]
}

cities_by_state.each do |state, cities|
  cities.each do |name, localities|
    city = City.find_or_create_by!(name:, state:)
    localities.each { |locality| Locality.find_or_create_by!(city:, name: locality) }
  end
end

# From the design's BUILDERS constant.
[ "Aurum Developers", "Nirvana Realty", "Skyline Group", "Trident Estates", "Vaayu Infra" ]
  .each { |name| Builder.find_or_create_by!(name:) }

# The design's TYPOLOGIES. bedrooms is what budget matching sorts on; villas and
# penthouses have no meaningful count, so they stay null.
[
  [ "1 RK", 1.0 ], [ "1 BHK", 1.0 ], [ "1.5 BHK", 1.5 ], [ "2 BHK", 2.0 ],
  [ "2.5 BHK", 2.5 ], [ "3 BHK", 3.0 ], [ "3.5 BHK", 3.5 ],
  [ "Villa", nil ], [ "Penthouse", nil ]
].each_with_index do |(name, bedrooms), index|
  Typology.find_or_create_by!(name:) { |t| t.bedrooms = bedrooms }.update!(sort_order: index)
end

# The design's SOURCES. `category` groups the two portals so the source report
# can roll them up.
[
  [ "Portal — Housing", "portal" ],
  [ "Portal — 99acres", "portal" ],
  [ "Portal — Magicbricks", "portal" ],
  [ "Referral", "referral" ],
  [ "Walk-in", "walk_in" ],
  [ "Social / Meta", "social" ],
  [ "Cold call", "outbound" ],
  [ "Telecalling", "outbound" ],
  [ "Builder Microsite", "other" ],
  [ "Website", "other" ]
].each_with_index do |(name, category), index|
  LeadSource.find_or_create_by!(name:) { |s| s.category = category }.update!(sort_order: index)
end

# The design's LEAD_STATUSES. The is_dead / is_booked flags are what let the
# reports be written without hardcoding status names in SQL.
[
  [ "New", false, false ],
  [ "Hot", false, false ],
  [ "Followup", false, false ],
  [ "Visit planned", false, false ],
  [ "Negotiation", false, false ],
  [ "Booked", false, true ],
  [ "Dead", true, false ]
].each_with_index do |(name, is_dead, is_booked), index|
  LeadStatus.find_or_create_by!(name:).update!(
    sort_order: index, is_dead:, is_booked:, is_terminal: is_dead || is_booked
  )
end

# Asked for sale leads, deliberately not asked for rentals.
[ "Under construction", "Ready possession" ].each_with_index do |name, index|
  PropertyType.find_or_create_by!(name:).update!(sort_order: index)
end

puts "Seeding plans…"

# Matches the design's drawer: "Growth plan · active · ₹2,499/mo".
[
  { name: "Starter", price: 999, max_users: 1, max_devices: 2, sort_order: 0 },
  { name: "Growth", price: 2_499, max_users: 5, max_devices: 3, sort_order: 1 },
  { name: "Scale", price: 5_999, max_users: nil, max_devices: 5, sort_order: 2 }
].each do |attributes|
  Plan.find_or_create_by!(name: attributes[:name]).update!(**attributes, interval: "month", active: true)
end

summary = <<~COUNTS
  Reference data ready.
    cities         #{City.count}
    localities     #{Locality.count}
    builders       #{Builder.count}
    typologies     #{Typology.count}
    lead sources   #{LeadSource.count}
    lead statuses  #{LeadStatus.count}
    property types #{PropertyType.count}
    plans          #{Plan.count}
COUNTS

next_steps =
  if AdminUser.exists?
    "Sign in at /admin. Run `bin/rails admin:list` to see who can."
  else
    <<~FIRST_RUN.strip
      No admin exists yet, so nobody can sign in. Create one:

        ADMIN_EMAIL=you@example.com bin/rails admin:create

      Then, for something to click through in development:

        bin/rails demo:seed
    FIRST_RUN
  end

puts "\n#{summary}\n#{next_steps}\n"
