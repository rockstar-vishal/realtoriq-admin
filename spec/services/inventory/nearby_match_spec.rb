# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Nearby interest matching" do
  let(:firm) { create(:firm) }
  let(:other_firm) { create(:firm, name: "Mehta Estates") }
  let(:city) { create(:city, name: "Mumbai") }
  let(:other_city) { create(:city, name: "Pune") }
  let(:kharghar) { create(:locality, city:, name: "Kharghar") }
  let(:kamothe) { create(:locality, city:, name: "Kamothe") }
  let(:boisar) { create(:locality, city:, name: "Boisar") }
  let(:panvel) { create(:locality, city:, name: "Panvel") }
  let(:airoli) { create(:locality, city:, name: "Airoli") }
  let(:baner) { create(:locality, city: other_city, name: "Baner") }
  let(:two_bhk) { create(:typology, name: "2 BHK") }
  let(:status) { create(:lead_status, :new_lead) }
  let!(:under_type) { create(:property_type, name: "Under construction") }
  let(:builder) { create(:builder, firm: nil) }

  before { Current.firm = firm }
  after do
    Current.reset
    NearbyMatching.delete_all
  end

  def shifted(north_m: 0, east_m: 0)
    Inventory::Geo.offset(19.05, 73.07, north_m:, east_m:)
  end

  def locate(locality, north_m: 0, east_m: 0)
    lat, lng = shifted(north_m:, east_m:)
    locality.update!(lat:, lng:)
    locality
  end

  def enable_nearby!
    NearbyMatching.enable!
  end

  def buyer(localities, name: "Asha")
    create(:lead, firm:, lead_status: status, budget_max: 10_000_000, transaction_type: "sale",
      property_type: under_type, name:).tap do |lead|
      lead.typologies << two_bhk
      Array(localities).each { |locality| lead.localities << locality }
    end
  end

  def stock(locality, name:, north_m: 0, east_m: 0, price: 10_000_000, pinned: true, firm: self.firm)
    lat, lng = pinned ? shifted(north_m:, east_m:) : [ nil, nil ]
    create(:project, firm:, city: locality&.city || city, locality:, builder:, name:, starting_budget: price,
      possession_on: Date.new(2027, 6, 1), possession_label: nil, lat:, lng:).tap do |project|
      create(:project_typology, project:, typology: two_bhk, starting_price: price)
    end
  end

  def catalog(locality, name:, price:)
    Current.set(firm: nil, firm_scope_bypassed: true) do
      project = create(:project, :catalog, firm: nil, name:, builder:, city: locality.city, locality:,
        starting_budget: price, external_ref: "PR#{SecureRandom.hex(4).upcase}",
        possession_on: Date.new(2027, 6, 1), possession_label: nil)
      create(:project_typology, project:, typology: two_bhk, starting_price: price)
      project
    end
  end

  def names_for(lead, query: nil)
    Inventory::MatchInventory.new(lead:).result(query:)
  end

  it "fills the list with named localities before a closer, better-priced neighbor" do
    enable_nearby!
    locate(kharghar)
    locate(kamothe, east_m: 2_000)
    locate(boisar, north_m: 7_000)
    locate(baner, east_m: 3_000)
    lead = buyer(kharghar)
    far = stock(kharghar, name: "Far Kharghar", east_m: 5_000, price: 20_000_000)
    close = stock(kamothe, name: "Close Kamothe", east_m: 2_000)
    stock(boisar, name: "Boisar Vista", north_m: 7_000)
    stock(baner, name: "Baner Vista", east_m: 3_000)
    create(:project, firm: other_firm, city:, locality: kamothe, builder:, name: "Private Kamothe",
      starting_budget: 10_000_000, possession_on: Date.new(2027, 6, 1), possession_label: nil,
      lat: shifted(east_m: 2_000)[0], lng: shifted(east_m: 2_000)[1])

    result = names_for(lead)
    rows = result[:matches]

    expect(rows.map { |row| row[:name] }).to eq([ "Far Kharghar", "Close Kamothe" ])
    expect(rows.map { |row| row[:group] }).to eq(%w[locality nearby])
    expect(rows.first[:score]).to be < rows.last[:score]
    expect(rows.first[:distance_m]).to be > rows.last[:distance_m]
    expect(rows.first[:matched_on]).to include("locality")
    expect(rows.last[:matched_on]).to include("nearby")
    expect(rows.first[:near_shortlist]).to be(false)
    expect(rows.first[:id]).to eq(far.id)
    expect(rows.last[:id]).to eq(close.id)
    expect(result[:interest_localities]).to eq([ { id: kharghar.id, name: "Kharghar" } ])
    expect(result[:neighbor_localities].map { |row| row[:name] }).to eq([ "Kamothe" ])
    expect(LocalityNeighbor.where(locality: kharghar, neighbor_locality: boisar)).to be_none
    expect(LocalityNeighbor.where(locality: kharghar, neighbor_locality: baner)).to be_none
  end

  it "gives every named-locality slot to the first group, and search returns the neighbor" do
    enable_nearby!
    locate(kharghar)
    locate(kamothe, east_m: 2_000)
    lead = buyer(kharghar)
    50.times { |index| stock(kharghar, name: format("Named %02d", index), price: 20_000_000) }
    neighbor = stock(kamothe, name: "Zebra Neighbor", east_m: 2_000)

    result = names_for(lead)
    expect(result[:matches].size).to eq(50)
    expect(result[:truncated]).to be(true)
    expect(result[:matches].map { |row| row[:group] }).to all(eq("locality"))
    expect(result[:matches].map { |row| row[:id] }).not_to include(neighbor.id)
    expect(result[:matches].first[:score]).to be < 90

    found = names_for(lead, query: "zebra")
    expect(found[:matches].map { |row| row[:id] }).to eq([ neighbor.id ])
    expect(found[:truncated]).to be(false)
    expect(found[:matches].first[:score]).to be > result[:matches].first[:score]
  end

  it "does not walk neighbor-of-neighbor, and stays exact until nearby matching is on" do
    locate(kharghar)
    locate(kamothe, north_m: 4_000)
    locate(panvel, north_m: 8_000)
    lead = buyer(kharghar)
    stock(kharghar, name: "In Kharghar")
    stock(kamothe, name: "In Kamothe", north_m: 4_000)
    stock(panvel, name: "In Panvel", north_m: 8_000)

    expect(names_for(lead)[:matches].map { |row| row[:name] }).to eq([ "In Kharghar" ])
    expect(LocalityNeighbor.where(locality: kharghar, neighbor_locality: panvel)).to be_none
    expect(LocalityNeighbor.where(locality: kamothe, neighbor_locality: panvel)).to exist

    enable_nearby!
    expect(names_for(lead)[:matches].map { |row| row[:name] }).to eq([ "In Kharghar", "In Kamothe" ])
  end

  it "ranks a pin circle ahead of a named locality, including a tower outside the neighbor line" do
    enable_nearby!
    locate(kharghar)
    locate(panvel, east_m: 12_000)
    locate(airoli, north_m: 9_000)
    lead = buyer(kharghar)
    tagged = stock(kharghar, name: "Tagged Tower", north_m: 4_000)
    lead.lead_projects.create!(project: tagged, firm:)
    close = stock(kharghar, name: "Close Kharghar", north_m: 4_500)
    pin_only = stock(nil, name: "Pin only", north_m: 4_000, east_m: 1_000)
    panvel_tower = stock(panvel, name: "Panvel tower", north_m: 4_000, east_m: 2_000)
    airoli_center = stock(airoli, name: "Airoli center", north_m: 9_000, pinned: false)
    far = stock(kharghar, name: "Far Kharghar", north_m: -3_000)
    other_city = create(:city, name: "Nashik")
    nashik = create(:locality, city: other_city, name: "Gangapur")
    stock(nashik, name: "Other city", north_m: 4_000, east_m: 500)

    rows = names_for(lead)[:matches]

    expect(rows.map { |row| row[:name] }).to eq(
      [ "Close Kharghar", "Pin only", "Panvel tower", "Airoli center", "Far Kharghar" ]
    )
    expect(rows.map { |row| row[:id] }).to eq([ close.id, pin_only.id, panvel_tower.id, airoli_center.id, far.id ])
    expect(rows.map { |row| [ row[:group], row[:near_shortlist] ] }).to eq(
      [ [ "locality", true ], [ "nearby", true ], [ "nearby", true ], [ "nearby", true ], [ "locality", false ] ]
    )
    expect(rows.map { |row| row[:name] }).not_to include("Tagged Tower", "Other city")
    expect(rows.first[:distance_m]).to be < 1_000
    expect(rows.last[:distance_m]).to be_within(50).of(3_000)
  end

  it "opens the same circle from a mapped property" do
    enable_nearby!
    locate(kharghar)
    locate(panvel, east_m: 12_000)
    lead = buyer(kharghar)
    lat, lng = shifted
    building = create(:building, firm:, city:, locality: kharghar, lat:, lng:)
    mapped = create(:property, firm:, typology: two_bhk, price: 10_000_000, building:)
    lead.lead_properties.create!(property: mapped, firm:)
    stock(panvel, name: "Near the flat", north_m: 2_000)
    stock(kharghar, name: "Far in Kharghar", north_m: 8_000)

    rows = names_for(lead)[:matches]
    expect(rows.map { |row| row[:name] }).to eq([ "Near the flat", "Far in Kharghar" ])
    expect(rows.first[:near_shortlist]).to be(true)
    expect(rows.last[:group]).to eq("locality")
    expect(rows.map { |row| row[:id] }).not_to include(mapped.id)
  end

  it "ignores a tagged pin that sits more than 20 km from its locality, and a withdrawn mapping" do
    enable_nearby!
    locate(kharghar)
    locate(panvel, north_m: 30_000)
    lead = buyer(kharghar)
    drifted = stock(kharghar, name: "Drifted pin", north_m: 25_000)
    lead.lead_projects.create!(project: drifted, firm:)
    beside = stock(kharghar, name: "Beside the center")
    stock(panvel, name: "Beside the bad pin", north_m: 27_000)
    withdrawn = stock(panvel, name: "Withdrawn hook", east_m: 10_000)
    near_withdrawn = stock(panvel, name: "Near withdrawn", east_m: 11_000)
    join = lead.lead_projects.create!(project: withdrawn, firm:)
    join.update!(withdrawn_at: Time.current)

    rows = names_for(lead)[:matches]
    expect(rows.map { |row| row[:id] }).to eq([ beside.id ])
    expect(rows.first[:near_shortlist]).to be(true)
    expect(rows.map { |row| row[:id] }).not_to include(drifted.id, withdrawn.id, near_withdrawn.id)
  end

  it "hides a catalog neighbor that does not clear 50 and shows an own neighbor that clears 30" do
    enable_nearby!
    locate(kharghar)
    locate(kamothe, east_m: 2_000)
    lead = buyer(kharghar)
    stock(kamothe, name: "Own nearby", east_m: 2_000, price: 20_000_000)
    catalog(kamothe, name: "Catalog miss", price: 20_000_000)
    fit = catalog(kamothe, name: "Catalog fit", price: 10_000_000)

    rows = names_for(lead)[:matches]
    expect(rows.map { |row| row[:name] }).to eq([ "Catalog fit", "Own nearby" ])
    expect(rows.map { |row| row[:group] }).to eq(%w[nearby nearby])
    expect(rows.first[:id]).to eq(fit.id)
    expect(rows.first[:score]).to be > 50
    expect(rows.last[:score]).to be > 30
    expect(rows.last[:score]).to be <= 50
  end

  it "lists buyers by pin, then named locality, then neighbor" do
    enable_nearby!
    locate(kharghar)
    locate(kamothe, east_m: 2_000)
    locate(panvel, east_m: 12_000)
    user = create(:user, :super_admin, firm:)
    listing = stock(kharghar, name: "Listing")
    named = buyer(kharghar, name: "Named")
    neighbor = buyer(kamothe, name: "Neighbor")
    pinned = buyer(panvel, name: "Pinned")
    hook = stock(panvel, name: "Their tower", north_m: 2_000)
    pinned.lead_projects.create!(project: hook, firm:)

    rows = Inventory::MatchLeads.new(user:, project: listing).call
    expect(rows.map { |row| row[:name] }).to eq(%w[Pinned Named Neighbor])
    expect(rows.map { |row| row[:group] }).to eq(%w[nearby locality nearby])
    expect(rows.first[:near_shortlist]).to be(true)
    expect(rows.second[:near_shortlist]).to be(false)
    expect(rows.first[:score]).to be < rows.second[:score]
  end

  it "writes the same order as the live match and does not notify when nearby matching is turned on" do
    locate(kharghar)
    locate(kamothe, east_m: 2_000)
    create(:subscription, firm:)
    create(:user, :super_admin, firm:)
    lead = buyer(kharghar, name: "Asha")
    stock(kharghar, name: "Named", price: 20_000_000)
    stock(kamothe, name: "Neighbor", east_m: 2_000)

    expect(Matches::Notify).not_to receive(:call)
    travel_to Time.find_zone("Asia/Kolkata").local(2026, 10, 8, 11) do
      Matches::EnableNearby.call
    end

    digest = MatchDigest.find_by!(firm:)
    live = names_for(lead)[:matches].map { |row| "#{row[:kind]}:#{row[:id]}" }
    stored = digest.lead_items.find { |item| item["lead_id"] == lead.id }["match_ids"]

    expect(live).to eq([ "project:#{Project.find_by!(name: 'Named').id}", "project:#{Project.find_by!(name: 'Neighbor').id}" ])
    expect(stored).to eq(live)
    expect(digest.notification_pending).to be(false)
    expect(digest.notified_fingerprint).to eq(digest.fingerprint)
    expect(Notification.across_firms.count).to eq(0)
    expect(NearbyMatching.enabled?).to be(true)
    expect(Matches::ScanLock.held?(firm)).to be(false)
  end

  it "puts a pin-circle listing in the quiet digest" do
    locate(kharghar)
    locate(panvel, east_m: 12_000)
    create(:subscription, firm:)
    lead = buyer(panvel, name: "Pinned")
    hook = stock(panvel, name: "Their tower", north_m: 1_000)
    lead.lead_projects.create!(project: hook, firm:)
    near = stock(kharghar, name: "Near the pin", north_m: 1_200)
    lat, lng = shifted(north_m: 1_200)
    building = create(:building, firm:, city:, locality: kharghar, lat:, lng:)
    create(:property, firm:, typology: two_bhk, price: 10_000_000, status: "available", building:)

    travel_to Time.find_zone("Asia/Kolkata").local(2026, 10, 8, 11) do
      Matches::EnableNearby.call
    end

    stored = MatchDigest.find_by!(firm:).lead_items.find { |item| item["lead_id"] == lead.id }["match_ids"]
    expect(stored).to eq([ "project:#{near.id}" ])
    expect(Matches::ScanLock.held?(firm)).to be(false)
  end

  it "matches another firm's buyer from a tagged pin and does not name them" do
    enable_nearby!
    locate(kharghar)
    locate(panvel, east_m: 12_000)
    ready = create(:property_type, name: "Ready possession")
    building = create(:building, firm:, city:, locality: kharghar, lat: shifted[0], lng: shifted[1])
    listing = create(:property, firm:, typology: two_bhk, price: 10_000_000, listed_on_marketplace: true,
      status: "available", building:)
    buyer = nil
    Current.set(firm: other_firm) do
      buyer = create(:lead, firm: other_firm, lead_status: status, budget_max: 10_000_000,
        transaction_type: "sale", property_type: ready, name: "Secret Name")
      buyer.typologies << two_bhk
      buyer.localities << panvel
      hook = stock(panvel, name: "Private tower", north_m: 1_000, firm: other_firm)
      buyer.lead_projects.create!(project: hook, firm: other_firm)
    end

    rows = Inventory::MarketplaceLeadMatches.new(property: listing).call

    expect(rows.map { |row| row[:code] }).to eq([ buyer.code ])
    expect(rows.first[:group]).to eq("nearby")
    expect(rows.first[:distance_m]).to be_within(50).of(1_000)
    expect(rows.first.keys).to contain_exactly(
      :firm_id, :firm_name, :code, :localities, :configurations, :marketplace, :distance_m, :group
    )
    text = rows.first.values.join(" ")
    expect(text).not_to include("Secret Name")
    expect(text).not_to include("Private tower")
  end
end
