# frozen_string_literal: true
#
# One-off: align RealtorIQ's city/locality masters with turbo (same canonical list,
# see turbo-rails8/migration/consolidate_locations.rb). Turbo pushes project city +
# locality NAMES to RealtorIQ, so both sides must use the same names or ingest will
# fail ("City X is not in RealtorIQ") or auto-create duplicate localities.
#
#   * Navi Mumbai and Thane stop being cities: their localities become Mumbai localities.
#   * Mumbai gets the curated 99 localities (East/West split for the big suburbs).
#   * Old plain names are remapped:
#       Andheri / Bandra / Borivali / Malad  → "<name> West" for buildings, projects, firms;
#                                              lead PREFERENCES get BOTH East and West (no lost matches)
#       Thane West / Ghodbunder Road / Kolshet / Majiwada → "Thane"
#   * Pune and Nashik get the same lists as turbo (existing rows reused).
#
# Updates buildings, projects, firms (city_id + locality_id) and lead_localities, then
# deletes the retired localities and the two cities.
#
# Usage (DRY RUN by default — everything runs in a transaction that is rolled back):
#   RAILS_ENV=production bin/rails runner script/consolidate_locations.rb
#   APPLY=1 RAILS_ENV=production bin/rails runner script/consolidate_locations.rb
#
# Guards — the run rolls back (and APPLY refuses) when any fails:
#   * two localities with the same name in one city, or two cities with the same name;
#   * a building would collide with another of the same firm/name/locality (unique index);
#   * any building/project/firm whose city differs from its locality's city.
# Run this BEFORE turbo's consolidate_locations.rb: turbo re-pushes the affected shared
# projects when it applies, with city "Mumbai" and the new locality names.

APPLY = ENV["APPLY"] == "1"
ActiveRecord::Base.logger.level = Logger::ERROR if ActiveRecord::Base.logger
cx = ActiveRecord::Base.connection
q = ->(v) { cx.quote(v) }

STATE = "Maharashtra"
TARGET_CITY = "Mumbai"
MERGE_CITIES = ["Navi Mumbai", "Thane"].freeze
SINGLE_REF_TABLES = %w[buildings projects firms].freeze

CANONICAL = {
  "Mumbai" => [
    "Colaba", "Cuffe Parade", "Nariman Point", "Churchgate", "Fort", "Marine Lines",
    "Girgaon", "Grant Road", "Malabar Hill", "Napean Sea Road", "Peddar Road", "Breach Candy",
    "Tardeo", "Mumbai Central", "Mahalaxmi", "Byculla", "Mazgaon", "Worli",
    "Lower Parel", "Parel", "Sewri", "Wadala", "Prabhadevi", "Dadar East",
    "Dadar West", "Mahim", "Matunga", "Sion", "Bandra East", "Bandra West",
    "BKC", "Khar West", "Santacruz East", "Santacruz West", "Vile Parle East", "Vile Parle West",
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
  ],
  "Pune" => [
    "Wakad", "Baner", "Balewadi", "Hinjewadi", "Tathawade", "Punawale",
    "Pashan", "Sus", "Bavdhan", "Pimple Saudagar", "Pimple Gurav", "Aundh",
    "Kharadi", "Wagholi", "Dhanori", "Mahalunge", "Warje", "Bibwewadi",
    "Chinchwad", "Rahatani", "Marunji", "Bhugaon", "Hadapsar", "Mundhwa",
    "Bund Garden", "Wakdewadi", "Kiwale", "NIBM", "Vishal Nagar", "Moshi",
    "Charholi", "Manchar", "Alephata", "Kothrud"
  ],
  "Nashik" => [
    "Gangapur Road", "Indira Nagar", "Panchavati"
  ]
}.freeze

# [current city, current locality name] => target Mumbai localities.
# First entry is used where only one locality fits (buildings, projects, firms);
# lead preferences get all of them.
LOCALITY_MAP = {
  ["Mumbai", "Andheri"]           => ["Andheri West", "Andheri East"],
  ["Mumbai", "Bandra"]            => ["Bandra West", "Bandra East"],
  ["Mumbai", "Borivali"]          => ["Borivali West", "Borivali East"],
  ["Mumbai", "Malad"]             => ["Malad West", "Malad East"],
  ["Thane", "Thane West"]         => ["Thane"],
  ["Thane", "Ghodbunder Road"]    => ["Thane"],
  ["Thane", "Kolshet"]            => ["Thane"],
  ["Thane", "Majiwada"]           => ["Thane"]
}.freeze

def norm(s) = s.to_s.strip.downcase.gsub(/\s+/, " ")

bad = LOCALITY_MAP.values.flatten.uniq - CANONICAL[TARGET_CITY]
abort "Map targets missing from CANONICAL: #{bad.inspect}" if bad.any?

find_city = ->(name) { City.where("LOWER(name) = ? AND state = ?", name.downcase, STATE).first }
cities = (CANONICAL.keys + MERGE_CITIES).index_with { |n| find_city.(n) }
missing = CANONICAL.keys.select { |n| cities[n].nil? }
abort "Target cities not found: #{missing.join(', ')}" if missing.any?
mumbai = cities[TARGET_CITY]
merge_city_ids = MERGE_CITIES.filter_map { |n| cities[n]&.id }

puts "===== REALTORIQ CITIES & LOCALITIES #{APPLY ? '(APPLY)' : '(DRY RUN — rolled back)'} ====="
puts "Merging into #{TARGET_CITY}: #{MERGE_CITIES.map { |n| "#{n}#{cities[n] ? '' : ' (absent)'}" }.join(', ')}"

stats = Hash.new(0)
warnings = []
guard_failures = []

ref_count = lambda do |col, id|
  tables = col == :locality_id ? SINGLE_REF_TABLES + %w[lead_localities] : SINGLE_REF_TABLES
  tables.sum { |t| cx.select_value("SELECT COUNT(*) FROM #{t} WHERE #{col} = #{q.(id)}").to_i }
end

ActiveRecord::Base.transaction do
  now = q.(Time.current)

  # 1. Canonical localities: reuse same-named rows (in the target city first, then in a
  #    merging city — moved across), otherwise create.
  canon = {} # [city, name] => id
  CANONICAL.each do |city_name, names|
    city = cities[city_name]
    names.each do |name|
      scope_ids = city_name == TARGET_CITY ? [city.id] + merge_city_ids : [city.id]
      rows = Locality.where(city_id: scope_ids).to_a.select { |l| norm(l.name) == norm(name) }
      row = rows.find { |l| l.city_id == city.id } || rows.first
      if row
        if row.name != name || row.city_id != city.id
          # a same-named row may already exist in the target city → handled as a merge below
          cx.execute("UPDATE localities SET name = #{q.(name)}, city_id = #{q.(city.id)}, active = TRUE, updated_at = #{now} WHERE id = #{q.(row.id)}")
          stats[:canonical_moved_or_renamed] += 1
        end
      else
        row = Locality.create!(city:, name:, active: true)
        stats[:canonical_created] += 1
      end
      canon[[city_name, name]] = row.id
    end
  end
  keeper_ids = canon.values.to_set

  # 2. Work out where every non-canonical locality in Mumbai / merging cities goes.
  remap = {} # old id => [target ids] (first = primary)
  Locality.includes(:city).where(city_id: [mumbai.id] + merge_city_ids).where.not(id: keeper_ids.to_a).find_each do |l|
    explicit = LOCALITY_MAP[[l.city.name, l.name]]
    targets =
      if explicit then explicit.map { |n| canon[[TARGET_CITY, n]] }
      elsif (hit = CANONICAL[TARGET_CITY].find { |n| norm(n) == norm(l.name) }) then [canon[[TARGET_CITY, hit]]]
      end
    if targets
      remap[l.id] = targets
    elsif merge_city_ids.include?(l.city_id)
      # not in the curated list: keep it, just move it into Mumbai (reported for review)
      clash = Locality.where(city_id: mumbai.id).where("LOWER(name) = ?", l.name.downcase).where.not(id: l.id).first
      if clash
        remap[l.id] = [clash.id]
      else
        cx.execute("UPDATE localities SET city_id = #{q.(mumbai.id)}, updated_at = #{now} WHERE id = #{q.(l.id)}")
        warnings << "kept non-curated locality #{l.name.inspect} (was #{l.city.name}) — moved into Mumbai; review"
      end
    else
      warnings << "non-curated Mumbai locality #{l.name.inspect} left as is; review"
    end
  end

  # 3. Buildings are unique per (firm, name, locality): refuse to merge two into one.
  primary = remap.transform_values(&:first)
  if primary.any?
    rows = cx.select_rows("SELECT id, firm_id, LOWER(name), locality_id FROM buildings")
    groups = rows.group_by { |_, firm, name, loc| [firm, name, primary.fetch(loc, loc)] }
    groups.each_value do |g|
      next if g.size < 2
      guard_failures << "buildings would collide after merge (same firm/name/locality): #{g.map(&:first).join(', ')}"
    end
  end

  # 4. Repoint references.
  puts "\n--- Locality remaps ---"
  remap.each do |old_id, targets|
    old_name = Locality.find(old_id).name
    counts = (SINGLE_REF_TABLES + %w[lead_localities]).to_h { |t| [t, cx.select_value("SELECT COUNT(*) FROM #{t} WHERE locality_id = #{q.(old_id)}").to_i] }
    names = targets.map { |id| Locality.find(id).name }
    puts "  #{old_name.inspect} → #{names.join(' + ')}   #{counts.map { |t, n| "#{t}=#{n}" }.join(' ')}"
    SINGLE_REF_TABLES.each do |t|
      cx.execute("UPDATE #{t} SET locality_id = #{q.(targets.first)}, city_id = #{q.(mumbai.id)} WHERE locality_id = #{q.(old_id)}")
    end
    targets.each do |tid|
      stats[:lead_preferences_added] += cx.update(<<~SQL)
        INSERT INTO lead_localities (id, lead_id, locality_id, created_at, updated_at)
        SELECT gen_random_uuid(), lead_id, #{q.(tid)}, #{now}, #{now}
        FROM lead_localities WHERE locality_id = #{q.(old_id)}
        ON CONFLICT (lead_id, locality_id) DO NOTHING
      SQL
    end
    stats[:lead_preferences_removed] += cx.update("DELETE FROM lead_localities WHERE locality_id = #{q.(old_id)}")
  end

  if merge_city_ids.any?
    SINGLE_REF_TABLES.each do |t|
      stats[:"#{t}_moved_to_mumbai"] += cx.update("UPDATE #{t} SET city_id = #{q.(mumbai.id)} WHERE city_id IN (#{merge_city_ids.map(&q).join(',')})")
    end
  end

  # 5. City always follows the locality.
  SINGLE_REF_TABLES.each do |t|
    stats[:"#{t}_city_fixed"] += cx.update("UPDATE #{t} x SET city_id = l.city_id FROM localities l WHERE x.locality_id = l.id AND x.city_id IS DISTINCT FROM l.city_id")
  end

  # 6. Delete retired localities and cities.
  remap.each_key do |id|
    if ref_count.(:locality_id, id).positive?
      guard_failures << "locality #{id} still referenced after remap"
      next
    end
    cx.execute("DELETE FROM localities WHERE id = #{q.(id)}")
    stats[:localities_deleted] += 1
  end
  merge_city_ids.each do |id|
    left = Locality.where(city_id: id).count
    refs = ref_count.(:city_id, id)
    if left.positive? || refs.positive?
      guard_failures << "city #{id} not empty (#{left} localities, #{refs} refs)"
      next
    end
    cx.execute("DELETE FROM cities WHERE id = #{q.(id)}")
    stats[:cities_deleted] += 1
  end

  # Bust the broker app's reference-data ETag (keyed on MAX(updated_at); deletes alone don't move it).
  cx.execute("UPDATE cities SET updated_at = #{now} WHERE id = #{q.(mumbai.id)}")
  cx.execute("UPDATE localities SET updated_at = #{now} WHERE city_id = #{q.(mumbai.id)}")

  # 7. Guards.
  cx.select_rows("SELECT city_id, LOWER(TRIM(name)), COUNT(*) FROM localities GROUP BY 1, 2 HAVING COUNT(*) > 1").each do |c, n, k|
    guard_failures << "duplicate locality #{n.inspect} ×#{k} in city #{c}"
  end
  cx.select_rows("SELECT LOWER(TRIM(name)), state, COUNT(*) FROM cities GROUP BY 1, 2 HAVING COUNT(*) > 1").each do |n, s, k|
    guard_failures << "duplicate city #{n.inspect} (#{s}) ×#{k}"
  end
  SINGLE_REF_TABLES.each do |t|
    n = cx.select_value("SELECT COUNT(*) FROM #{t} x JOIN localities l ON l.id = x.locality_id WHERE x.city_id IS DISTINCT FROM l.city_id").to_i
    guard_failures << "#{t}: #{n} rows whose city differs from their locality's city" if n.positive?
  end

  puts "\n--- Summary ---"
  stats.sort.each { |k, v| puts "  #{k}: #{v}" }
  CANONICAL.each_key { |c| puts "  #{c} localities now: #{Locality.where(city_id: cities[c].id).count}" }
  puts "  Cities now: #{City.pluck(:name).sort.join(', ')}"
  if warnings.any?
    puts "\n--- Needs attention ---"
    warnings.each { |w| puts "  ! #{w}" }
  end
  if guard_failures.any?
    puts "\n--- GUARD FAILURES (#{APPLY ? 'rolled back, nothing applied' : 'APPLY would refuse'}) ---"
    guard_failures.each { |g| puts "  X #{g}" }
    raise ActiveRecord::Rollback
  end

  raise ActiveRecord::Rollback unless APPLY
end

puts(if APPLY && guard_failures.empty? then "\nAPPLIED. Now run turbo's migration/consolidate_locations.rb (it re-pushes shared projects)."
     elsif APPLY then "\nNOT APPLIED — fix the guard failures above and re-run."
     else "\nDRY RUN complete — nothing was saved. Re-run with APPLY=1 to apply." end)
