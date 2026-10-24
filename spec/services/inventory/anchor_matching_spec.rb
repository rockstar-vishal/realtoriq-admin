# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "Anchor matching" do
  include ActiveSupport::Testing::TimeHelpers

  let(:firm) { create(:firm) }
  let(:other_firm) { create(:firm, name: "Mehta Estates") }
  let(:city) { create(:city, name: "Mumbai") }
  let(:thane) { create(:city, name: "Thane") }
  let(:kharghar) { create(:locality, city:, name: "Kharghar") }
  let(:kamothe) { create(:locality, city:, name: "Kamothe") }
  let(:two_bhk) { create(:typology, name: "2 BHK") }
  let(:status) { create(:lead_status, :new_lead) }
  let!(:under_type) { create(:property_type, name: "Under construction") }
  let(:builder) { create(:builder, firm: nil) }

  before { Current.firm = firm }
  after do
    Current.reset
    NearbyMatching.delete_all
    AnchorMatching.delete_all
  end

  def shifted(north_m: 0, east_m: 0)
    Inventory::Geo.offset(19.05, 73.07, north_m:, east_m:)
  end

  def locate(locality, north_m: 0, east_m: 0)
    lat, lng = shifted(north_m:, east_m:)
    locality.update!(lat:, lng:)
    locality
  end

  def buyer(localities = kharghar, name: "Asha", property_type: under_type, **attrs)
    create(:lead, firm:, lead_status: status, budget_max: 10_000_000, transaction_type: "sale",
      property_type:, name:, **attrs).tap do |lead|
      lead.typologies << two_bhk
      Array(localities).compact.each { |locality| lead.localities << locality }
    end
  end

  def stock(locality, name:, north_m: 0, east_m: 0, price: 10_000_000, pinned: true, firm: self.firm)
    lat, lng = pinned ? shifted(north_m:, east_m:) : [ nil, nil ]
    create(:project, firm:, city: locality&.city || city, locality:, builder:, name:, starting_budget: price,
      possession_on: Date.new(2027, 6, 1), possession_label: nil, lat:, lng:, source: "own").tap do |project|
      create(:project_typology, project:, typology: two_bhk, starting_price: price)
    end
  end

  def catalog(locality, name:, north_m: 0, east_m: 0, price: 10_000_000, ref: "PRSHARED")
    lat, lng = shifted(north_m:, east_m:)
    Current.set(firm: nil, firm_scope_bypassed: true) do
      project = create(:project, :catalog, firm: nil, name:, builder:, city: locality.city, locality:,
        starting_budget: price, external_ref: ref, lat:, lng:,
        possession_on: Date.new(2027, 6, 1), possession_label: nil)
      create(:project_typology, project:, typology: two_bhk, starting_price: price)
      project
    end
  end

  def flat(locality, name: nil, north_m: 0, east_m: 0, price: 10_000_000, firm: self.firm, shared: false)
    lat, lng = shifted(north_m:, east_m:)
    building = create(:building, firm:, city: locality.city, locality:,
      name: name || "Tower #{SecureRandom.hex(3)}", lat:, lng:)
    create(:property, firm:, typology: two_bhk, price:, building:, listed_on_marketplace: shared, status: "available")
  end

  def visit(lead, project: nil, property: nil, visited_at: Time.current)
    row = create(:lead_visit, lead:, firm: lead.firm, visited_at:)
    LeadVisitProject.create!(lead_visit: row, project:, firm: lead.firm) if project
    LeadVisitProperty.create!(lead_visit: row, property:, firm: lead.firm) if property
    row
  end

  def enable_anchors!(radius: 6_000)
    AnchorMatching.enable!
    AnchorMatching.set_radius!(radius)
  end

  def rows_for(lead)
    Inventory::MatchInventory.new(lead:).result
  end

  def location_of(lead, project)
    rows_for(lead)[:matches].find { |row| row[:id] == project.id }&.dig(:score_breakdown, :location)
  end

  def queries
    count = 0
    callback = ->(*) { count += 1 }
    ActiveRecord::Base.uncached do
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    end
    count
  end

  # A second database session. The spec thread reuses the test connection, so
  # its advisory lock would be the same session and would not wait.
  def other_session_blocked?(firm)
    key = (firm.id.delete("-").to_i(16) % (1 << 62)) + 1
    hash = ActiveRecord::Base.connection_db_config.configuration_hash
    conn = PG.connect({
      host: hash[:host], port: hash[:port], dbname: hash[:database],
      user: hash[:username], password: hash[:password]
    }.compact)
    conn.exec("SET lock_timeout = '400ms'")
    conn.exec_params("SELECT pg_advisory_lock($1::bigint)", [ key ])
    conn.exec_params("SELECT pg_advisory_unlock($1::bigint)", [ key ])
    false
  rescue PG::Error => error
    raise unless error.message.match?(/lock/i)

    true
  ensure
    conn&.close
  end

  describe "anchor picking" do
    it "keeps the place, then visits newest first, then the shortlist, and caps at 3" do
      enable_anchors!
      lead = buyer
      lat, lng = shifted
      lead.update!(near_lat: lat, near_lng: lng, near_label: "Office")
      older = stock(kharghar, name: "Older Visit", north_m: 400)
      newer = stock(kharghar, name: "Newer Visit", north_m: 800)
      short = stock(kharghar, name: "Newer Shortlist", north_m: 1_200)
      visit(lead, project: older, visited_at: 2.days.ago)
      visit(lead, project: newer, visited_at: 1.day.ago)
      lead.lead_projects.create!(project: short, firm:, created_at: Time.current)

      anchors = Inventory::LeadAnchors.for([ lead ])[lead.id]

      expect(anchors.map(&:kind)).to eq(%w[placed visited visited])
      expect(anchors.map(&:name)).to eq([ "Office", "Newer Visit", "Older Visit" ])
      expect(anchors.map(&:name)).not_to include("Newer Shortlist")
    end

    it "lets a visit beat a newer shortlist, skips a withdrawn visit, and takes the next pinned listing" do
      enable_anchors!
      lead = buyer
      visited = stock(kharghar, name: "Visited", north_m: 300)
      withdrawn = stock(kharghar, name: "Withdrawn Visit", north_m: 500)
      unpinned = stock(kharghar, name: "No pin", pinned: false)
      nxt = stock(kharghar, name: "Next", north_m: 700)
      fresh = stock(kharghar, name: "Fresh shortlist", north_m: 900)
      visit(lead, project: visited, visited_at: 3.days.ago)
      visit(lead, project: withdrawn, visited_at: 2.days.ago)
      visit(lead, project: unpinned, visited_at: 1.day.ago)
      lead.lead_projects.create!(project: withdrawn, firm:, withdrawn_at: Time.current)
      lead.lead_projects.create!(project: fresh, firm:, created_at: Time.current)
      lead.lead_projects.create!(project: nxt, firm:, created_at: 1.hour.ago)

      names = Inventory::LeadAnchors.for([ lead ])[lead.id].map(&:name)

      expect(names).to eq([ "Visited", "Fresh shortlist", "Next" ])
      expect(names).not_to include("Withdrawn Visit", "No pin")
    end

    it "treats a booking copy and its catalog row as one anchor" do
      enable_anchors!
      lead = buyer
      listed = catalog(kharghar, name: "Catalog Twin", north_m: 200)
      copy = stock(kharghar, name: "Copy Twin", north_m: 200)
      copy.update!(external_ref: listed.external_ref)
      lead.lead_projects.create!(project: listed, firm:)
      lead.lead_projects.create!(project: copy, firm:)

      anchors = Inventory::LeadAnchors.for([ lead ])[lead.id]

      expect(anchors.size).to eq(1)
      expect([ listed.id, copy.id ]).to include(anchors.first.listing_id)
    end

    it "leaves a visited listing out of the lead's matches and does not measure that lead from it" do
      enable_anchors!
      locate(kharghar)
      lead = buyer
      visited = stock(kharghar, name: "Visited Tower")
      other = stock(kharghar, name: "Other Tower", north_m: 500)
      visit(lead, project: visited)
      user = create(:user, :super_admin, firm:)

      expect(rows_for(lead)[:matches].map { |row| row[:id] }).to contain_exactly(other.id)

      found = Inventory::MatchLeads.new(user:, project: visited).call.find { |row| row[:id] == lead.id }
      expect(found[:near_shortlist]).to be(false)
      expect(found[:anchor]).to be_nil
      expect(found[:distance_m]).to be_nil
    end

    it "names another firm's property with its card title" do
      enable_anchors!
      lead = buyer
      secret = flat(kharghar, name: "SECRET TOWER", firm: other_firm, shared: true)
      lead.lead_properties.create!(property: secret, firm:)

      anchor = Inventory::LeadAnchors.for([ lead ])[lead.id].first

      expect(anchor.other_firm).to be(true)
      expect(anchor.name).to eq("2 BHK in Kharghar")
      expect(anchor.name).not_to include("SECRET TOWER")
    end

    it "uses the same number of queries for 2 leads and for 50" do
      enable_anchors!
      build = lambda do |count|
        Array.new(count) do
          lead = buyer(name: "Batch #{SecureRandom.hex(2)}")
          project = stock(kharghar, name: "P #{SecureRandom.hex(2)}", north_m: 200)
          property = flat(kharghar)
          visit(lead, project:)
          lead.lead_properties.create!(property:, firm:)
          lead
        end
      end
      warmup = build.call(1)
      two = build.call(2)
      fifty = build.call(50)
      Inventory::LeadAnchors.for(warmup)
      small = queries { Inventory::LeadAnchors.for(two) }
      large = queries { Inventory::LeadAnchors.for(fifty) }

      expect(large).to eq(small)
    end
  end

  describe "graded points and order" do
    it "scores the thirds of 6 km and of 3 km, and 30 inside a preferred locality" do
      enable_anchors!
      bare = create(:locality, city:, name: "Bare")
      lead = buyer
      lat, lng = shifted
      lead.update!(near_lat: lat, near_lng: lng, near_label: "Office")
      near = stock(bare, name: "1.9", north_m: 1_900)
      mid = stock(bare, name: "3.9", north_m: 3_900)
      far = stock(bare, name: "5.9", north_m: 5_900)
      past = stock(kharghar, name: "6.1", north_m: 6_100)

      expect(location_of(lead, near)).to eq(30)
      expect(location_of(lead, mid)).to eq(25)
      expect(location_of(lead, far)).to eq(20)
      past_row = rows_for(lead)[:matches].find { |row| row[:id] == past.id }
      expect(past_row[:anchor]).to be_nil
      expect(past_row[:group]).to eq("locality")

      AnchorMatching.set_radius!(3_000)
      close = stock(bare, name: "0.9", north_m: 900)
      middle = stock(bare, name: "1.5", north_m: 1_500)
      edge = stock(bare, name: "2.9", north_m: 2_900)
      outside = stock(bare, name: "3.1", north_m: 3_100)
      expect(location_of(lead, close)).to eq(30)
      expect(location_of(lead, middle)).to eq(25)
      expect(location_of(lead, edge)).to eq(20)
      expect(rows_for(lead)[:matches].map { |row| row[:id] }).not_to include(outside.id)

      preferred = stock(kharghar, name: "Preferred ring", north_m: 5_000)
      AnchorMatching.set_radius!(6_000)
      expect(location_of(lead, preferred)).to eq(30)
    end

    it "sorts ring 1 before a higher-scoring ring 2, and an anchor row before a preferred one" do
      enable_anchors!
      bare = create(:locality, city:, name: "Bare")
      lead = buyer
      lat, lng = shifted
      lead.update!(near_lat: lat, near_lng: lng, near_label: "Office")
      low = stock(bare, name: "Ring one", north_m: 500, price: 20_000_000)
      high = stock(bare, name: "Ring two", north_m: 2_500)
      preferred = stock(kharghar, name: "Preferred", north_m: 8_000)

      names = rows_for(lead)[:matches].map { |row| row[:name] }

      expect(names.index("Ring one")).to be < names.index("Ring two")
      expect(names.index("Ring two")).to be < names.index("Preferred")
      expect(rows_for(lead)[:matches].find { |row| row[:name] == "Ring one" }[:score]).to be <
        rows_for(lead)[:matches].find { |row| row[:name] == "Ring two" }[:score]
    end
  end

  describe "across cities and unpinned listings" do
    it "matches across the Thane–Mumbai line only while anchor matching is on" do
      locate(kharghar)
      thane_locality = create(:locality, city: thane, name: "Ghodbunder")
      locate(thane_locality, north_m: 1_000)
      expect(LocalityNeighbor.where(locality: kharghar, neighbor_locality: thane_locality)).to be_none

      Inventory::RebuildLocalityNeighbors.rebuild_all(across_cities: true)
      expect(LocalityNeighbor.where(locality: kharghar, neighbor_locality: thane_locality)).to exist

      LocalityNeighbor.delete_all
      Inventory::RebuildLocalityNeighbors.call(city_id: city.id)
      Inventory::RebuildLocalityNeighbors.call(city_id: thane.id)
      expect(LocalityNeighbor.where(locality: kharghar, neighbor_locality: thane_locality)).to be_none

      NearbyMatching.enable!
      lead = buyer(thane_locality)
      lat, lng = shifted(north_m: 1_000)
      lead.update!(near_lat: lat, near_lng: lng, near_label: "Thane office")
      listing = stock(kharghar, name: "Mumbai listing")
      expect(rows_for(lead)[:matches].map { |row| row[:id] }).not_to include(listing.id)

      enable_anchors!
      expect(rows_for(lead)[:matches].map { |row| row[:id] }).to include(listing.id)
      Inventory::RebuildLocalityNeighbors.call(city_id: city.id)
      expect(LocalityNeighbor.where(locality: kharghar, neighbor_locality: thane_locality)).to exist
    end

    it "keeps an unpinned listing in its preferred locality and out of the anchor band" do
      enable_anchors!
      locate(kharghar)
      lead = buyer
      lat, lng = shifted
      lead.update!(near_lat: lat, near_lng: lng, near_label: "Office")
      unpinned = stock(kharghar, name: "No pin", pinned: false)

      row = rows_for(lead)[:matches].find { |match| match[:id] == unpinned.id }

      expect(row[:anchor]).to be_nil
      expect(row[:group]).to eq("locality")
      expect(row[:near_shortlist]).to be(false)
      expect(row[:distance_m]).to be_nil
    end
  end

  describe "shown distance and rounding" do
    it "shows a distance only from real points, in both modes" do
      locate(kharghar)
      locate(kamothe, east_m: 2_000)
      panvel = create(:locality, city:, name: "Panvel")
      locate(panvel, east_m: 15_000)
      NearbyMatching.enable!
      lead = buyer
      at_centre = stock(kharghar, name: "Thane centre")
      tagged = stock(panvel, name: "Centre fallback", pinned: false)
      lead.lead_projects.create!(project: tagged, firm:)
      beside = stock(panvel, name: "Beside the centre", east_m: 15_000)
      neighbor = stock(kamothe, name: "Neighbor", east_m: 2_000)

      off = rows_for(lead)[:matches].index_by { |row| row[:id] }
      expect(off[at_centre.id][:distance_m]).to be_nil
      expect(off[at_centre.id][:group]).to eq("locality")
      expect(off[beside.id][:distance_m]).to be_nil
      expect(off[beside.id][:near_shortlist]).to be(true)
      expect(off[neighbor.id][:distance_m]).to eq(
        Inventory::Geo.distance_m(kharghar.lat, kharghar.lng, neighbor.lat, neighbor.lng)
      )

      enable_anchors!
      lead.update!(near_lat: shifted(east_m: 15_000)[0], near_lng: shifted(east_m: 15_000)[1], near_label: "Office")
      on = rows_for(lead)[:matches].index_by { |row| row[:id] }
      expect(on[at_centre.id][:distance_m]).to be_nil
      expect(on[at_centre.id][:anchor]).to be_nil
      expect(on[at_centre.id][:group]).to eq("locality")
    end

    it "rounds another firm's property and another firm's leads, and leaves a catalog project exact" do
      enable_anchors!
      bare = create(:locality, city:, name: "Bare")
      ready_type = create(:property_type, name: "Ready possession")
      ready = buyer(name: "Ready buyer", property_type: ready_type)
      ready.update!(near_lat: shifted[0], near_lng: shifted[1], near_label: "Office")
      near = flat(bare, north_m: 120, firm: other_firm, shared: true)
      mid = flat(bare, north_m: 1_240, firm: other_firm, shared: true)
      far = flat(bare, north_m: 1_260, firm: other_firm, shared: true)
      project_lead = buyer(name: "Project buyer")
      project_lead.update!(near_lat: shifted[0], near_lng: shifted[1], near_label: "Office")
      listed = catalog(bare, name: "Exact catalog", north_m: 1_240, ref: "PREXACT")

      found = rows_for(ready)[:matches].index_by { |row| row[:id] }
      expect(found[near.id]).to include(distance_m: 500, distance_rounded: true)
      expect(found[mid.id]).to include(distance_m: 1_000, distance_rounded: true)
      expect(found[far.id]).to include(distance_m: 1_500, distance_rounded: true)
      exact = rows_for(project_lead)[:matches].find { |row| row[:id] == listed.id }
      expect(exact[:distance_rounded]).to be(false)
      expect(exact[:distance_m]).to be_within(5).of(1_240)

      shared = flat(kharghar, firm: other_firm, shared: true)
      hooked = buyer(name: "Hooked")
      hooked.lead_properties.create!(property: shared, firm:)
      beside = catalog(bare, name: "Beside their flat", north_m: 1_240, ref: "PRROUND")
      rounded = rows_for(hooked)[:matches].find { |row| row[:id] == beside.id }
      expect(rounded).to include(distance_rounded: true)
      expect(rounded[:distance_m]).to eq(1_000)

      listing = flat(kharghar, shared: true)
      outsider = nil
      Current.set(firm: other_firm) do
        outsider = create(:lead, firm: other_firm, lead_status: status, budget_max: 10_000_000,
          transaction_type: "sale", property_type: ready_type, name: "Secret Name", email: "secret@example.com")
        outsider.typologies << two_bhk
        outsider.update!(near_lat: shifted(north_m: 1_240)[0], near_lng: shifted(north_m: 1_240)[1], near_label: "Home")
      end
      marketplace = Inventory::MarketplaceLeadMatches.new(property: listing).call
      expect(marketplace.first[:distance_m]).to eq(1_000)
      expect(marketplace.first.keys).to contain_exactly(
        :firm_id, :firm_name, :code, :localities, :configurations, :marketplace, :distance_m, :group
      )
      expect(marketplace.first.values.join(" ")).not_to include("Secret Name", "Home", "secret@example.com")
    end
  end

  describe "one row per project" do
    it "lists the catalog row while it is active, then the copy, and a shortlist marks both" do
      locate(kharghar)
      listed = catalog(kharghar, name: "Catalog Row")
      copy = stock(kharghar, name: "Own Copy")
      copy.update!(external_ref: listed.external_ref)
      plain = stock(kharghar, name: "Plain", north_m: 100)
      plain.update!(external_ref: nil)
      lead = buyer
      create(:subscription, firm:)

      off = rows_for(lead)[:matches].map { |row| row[:id] }
      expect(off).to include(listed.id, copy.id, plain.id)

      enable_anchors!
      on = rows_for(lead)[:matches].map { |row| row[:id] }
      expect(on).to include(listed.id, plain.id)
      expect(on).not_to include(copy.id)

      digest = Matches::CurateFirm.call(firm:, announce: false)
      stored = digest.lead_items.find { |item| item["lead_id"] == lead.id }["match_ids"]
      expect(stored).to include("project:#{listed.id}")
      expect(stored).not_to include("project:#{copy.id}")

      listed.update!(status: "archived")
      expect(rows_for(lead)[:matches].map { |row| row[:id] }).to include(copy.id)

      listed.update!(status: "active")
      lead.lead_projects.create!(project: copy, firm:)
      expect(rows_for(lead)[:matches].map { |row| row[:id] }).not_to include(listed.id, copy.id)
    end
  end

  describe "switch off is today" do
    it "keeps today's rows, scores and order when the switch is off" do
      locate(kharghar)
      locate(kamothe, east_m: 2_000)
      NearbyMatching.enable!
      lead = buyer
      alpha = stock(kharghar, name: "Alpha")
      beta = stock(kamothe, name: "Beta", east_m: 2_000)
      gamma = stock(kharghar, name: "Gamma", north_m: 7_000)
      delta = stock(kharghar, name: "Delta", north_m: 6_500)
      lead.lead_projects.create!(project: gamma, firm:)
      far = create(:locality, city: thane, name: "Far")
      epsilon = stock(far, name: "Epsilon", north_m: 15_000)
      zeta = stock(far, name: "Zeta", north_m: 15_400)
      visit(lead, project: epsilon)
      lead.update!(near_lat: shifted(north_m: 15_000)[0], near_lng: shifted(north_m: 15_000)[1], near_label: "Far office")
      across_locality = create(:locality, city: thane, name: "Ghodbunder")
      locate(across_locality, north_m: 1_000)
      across = stock(across_locality, name: "Across", north_m: 1_000)
      listed = catalog(kharghar, name: "Catalog Row")
      copy = stock(kharghar, name: "Own Copy")
      copy.update!(external_ref: listed.external_ref)

      result = rows_for(lead)
      expect(AnchorMatching.enabled?).to be(false)
      expect(result[:anchors]).to eq([])
      expect(result[:matches].map { |row| row[:name] }).to eq(
        [ "Delta", "Alpha", "Catalog Row", "Own Copy", "Beta" ]
      )
      expect(result[:matches].map { |row| row[:score] }).to eq([ 100, 100, 100, 100, 90 ])
      expect(result[:matches].map { |row| row[:id] }).not_to include(gamma.id, zeta.id, epsilon.id, across.id)
      expect(result[:matches].map { |row| row[:anchor] }).to all(be_nil)
    end
  end

  describe "responses" do
    it "returns the anchor list, the row anchor, and near_shortlist for placed and shortlisted anchors" do
      enable_anchors!
      bare = create(:locality, city:, name: "Bare")
      lead = buyer
      lead.update!(near_lat: shifted[0], near_lng: shifted[1], near_label: "Office")
      placed = stock(bare, name: "From the office", north_m: 400)
      short = stock(kharghar, name: "Shortlisted", north_m: 4_000)
      lead.lead_projects.create!(project: short, firm:)
      from_short = stock(bare, name: "From the shortlist", north_m: 4_400)

      result = rows_for(lead)
      expect(result[:anchors].map { |anchor| anchor[:kind] }).to eq(%w[placed shortlisted])
      expect(result[:anchors].first).to include(listing_kind: nil, listing_id: nil, name: "Office")
      placed_row = result[:matches].find { |row| row[:id] == placed.id }
      short_row = result[:matches].find { |row| row[:id] == from_short.id }
      expect(placed_row[:near_shortlist]).to be(false)
      expect(placed_row[:anchor]).to eq(kind: "placed", name: "Office")
      expect(short_row[:near_shortlist]).to be(true)
      expect(short_row[:anchor]).to eq(kind: "shortlisted", name: "Shortlisted")
    end
  end

  describe "rake tasks" do
    before(:all) do
      Rails.application.load_tasks unless Rake::Task.task_defined?("matches:anchor_enable")
    end

    def run_task(name)
      Rake::Task[name].tap(&:reenable).invoke
    end

    it "moves a 5 km match out of the anchor band, writes a quiet digest, and refuses a bad radius" do
      create(:subscription, firm:)
      create(:user, :super_admin, firm:)
      bare = create(:locality, city:, name: "Bare")
      lead = buyer
      lead.update!(near_lat: shifted[0], near_lng: shifted[1], near_label: "Office")
      far = stock(bare, name: "Five km", north_m: 5_000)
      enable_anchors!
      expect(rows_for(lead)[:matches].map { |row| row[:id] }).to include(far.id)

      expect(Matches::Notify).not_to receive(:call)
      ENV["METRES"] = "3000"
      run_task("matches:anchor_radius")

      expect(AnchorMatching.radius_m).to eq(3_000)
      expect(rows_for(lead)[:matches].map { |row| row[:id] }).not_to include(far.id)
      digest = MatchDigest.find_by!(firm:)
      expect(digest.notification_pending).to be(false)
      expect(digest.notified_fingerprint).to eq(digest.fingerprint)
      expect(Notification.across_firms.count).to eq(0)

      expect { Matches::SetAnchorRadius.call(metres: 500) }.to raise_error(ArgumentError, /1000 and 6000/)
      expect { Matches::SetAnchorRadius.call(metres: 7_000) }.to raise_error(ArgumentError, /1000 and 6000/)
      expect(AnchorMatching.radius_m).to eq(3_000)
      AnchorMatching.disable!
      expect { Matches::SetAnchorRadius.call(metres: 3_000) }.to raise_error(ArgumentError, /off/)
    ensure
      ENV.delete("METRES")
    end

    it "enables and disables without a notification, locks the firm, and rebuilds pairs accordingly" do
      create(:subscription, firm:)
      locate(kharghar)
      thane_locality = create(:locality, city: thane, name: "Ghodbunder")
      locate(thane_locality, north_m: 1_000)
      blocked = false
      held_during_curate = nil
      allow(Matches::CurateFirm).to receive(:call).and_wrap_original do |method, **kwargs|
        if held_during_curate.nil?
          held_during_curate = Matches::ScanLock.held?(kwargs[:firm])
          blocked = other_session_blocked?(kwargs[:firm])
        end
        method.call(**kwargs)
      end
      expect(Matches::Notify).not_to receive(:call)

      Matches::EnableAnchors.call

      expect(held_during_curate).to be(true)
      expect(blocked).to be(true)
      expect(AnchorMatching.enabled?).to be(true)
      expect(NearbyMatching.enabled?).to be(true)
      expect(LocalityNeighbor.where(locality: kharghar, neighbor_locality: thane_locality)).to exist
      expect(Matches::ScanLock.held?(firm)).to be(false)
      expect(Notification.across_firms.count).to eq(0)

      Matches::DisableAnchors.call

      expect(AnchorMatching.enabled?).to be(false)
      expect(NearbyMatching.enabled?).to be(true)
      expect(LocalityNeighbor.where(locality: kharghar, neighbor_locality: thane_locality)).to be_none
      expect(Matches::ScanLock.held?(firm)).to be(false)
    end

    it "refuses to compare in production and leaves the switch and the pairs alone" do
      create(:subscription, firm:)
      locate(kharghar)
      lead = buyer(name: "Secret Client", email: "secret@example.com")
      lead.update!(mobile: "+919800011122", near_lat: shifted[0], near_lng: shifted[1], near_label: "Office")
      project = stock(kharghar, name: "Listed")
      lead.lead_projects.create!(project:, firm:)
      pairs = LocalityNeighbor.order(:locality_id, :neighbor_locality_id).pluck(:locality_id, :neighbor_locality_id, :distance_m)

      allow(Rails.env).to receive(:production?).and_return(true)
      expect { Matches::CompareAnchors.call }.to raise_error(Matches::CompareAnchors::Refused, /production/)
      expect { run_task("matches:anchor_compare") }.to raise_error(SystemExit)
      allow(Rails.env).to receive(:production?).and_return(false)

      io = StringIO.new
      Matches::CompareAnchors.call(io:)
      csv = Rails.root.join("tmp/anchor_compare.csv").read
      text = io.string + csv

      expect(AnchorMatching.count).to eq(0)
      expect(LocalityNeighbor.order(:locality_id, :neighbor_locality_id).pluck(:locality_id, :neighbor_locality_id, :distance_m)).to eq(pairs)
      expect(io.string).to include("leads compared")
      expect(text).to include(lead.code)
      expect(text).not_to include("Secret Client")
      expect(text).not_to include(lead.mobile)
      expect(text).not_to include(lead.email)
    end
  end
end
