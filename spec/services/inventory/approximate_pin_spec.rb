# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Approximate pins" do
  let(:firm) { create(:firm) }
  let(:city) { create(:city, name: "Mumbai") }
  let(:kharghar) { create(:locality, city:, name: "Kharghar") }
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

  def locate(locality)
    lat, lng = shifted
    locality.update!(lat:, lng:)
    locality
  end

  def buyer
    create(:lead, firm:, lead_status: status, budget_max: 10_000_000, transaction_type: "sale",
      property_type: under_type, name: "Asha").tap do |lead|
      lead.typologies << two_bhk
      lead.localities << kharghar
    end
  end

  def stock(name, lat:, lng:)
    create(:project, firm:, city:, locality: kharghar, builder:, name:, starting_budget: 10_000_000,
      possession_on: Date.new(2027, 6, 1), possession_label: nil, lat:, lng:, source: "own").tap do |project|
      create(:project_typology, project:, typology: two_bhk, starting_price: 10_000_000)
    end
  end

  def signature(lead)
    Inventory::MatchInventory.new(lead:).call.map { |row|
      [ row[:id], row[:name], row[:score], row[:distance_m], row[:group], row[:anchor], row[:near_shortlist] ]
    }
  end

  def mark_approximate(project)
    project.update_columns(lat: kharghar.lat, lng: kharghar.lng, pin_approximate: true)
  end

  it "matches exactly like an unpinned listing, shows no distance, and is never an anchor" do
    locate(kharghar)
    lead = buyer
    stand_in = stock("Centre stand-in", lat: nil, lng: nil)
    real = stock("Real tower", lat: shifted(east_m: 2_000)[0], lng: shifted(east_m: 2_000)[1])

    off = signature(lead)
    expect(off.map(&:first)).to include(stand_in.id, real.id)
    mark_approximate(stand_in)
    expect(signature(lead)).to eq(off)
    expect(signature(lead).find { |row| row[0] == stand_in.id }[3]).to be_nil

    stand_in.update_columns(lat: nil, lng: nil, pin_approximate: false)
    AnchorMatching.enable!
    AnchorMatching.set_radius!(6_000)
    lead.update!(near_lat: kharghar.lat, near_lng: kharghar.lng, near_label: "Office")
    on = signature(lead)
    mark_approximate(stand_in)
    expect(signature(lead)).to eq(on)
    row = signature(lead).find { |item| item[0] == stand_in.id }
    expect(row[3]).to be_nil
    expect(row[5]).to be_nil

    at_centre = stock("Exact centre", lat: kharghar.lat, lng: kharghar.lng)
    shown = signature(lead).find { |item| item[0] == at_centre.id }
    expect(shown[3]).to eq(0)
    at_centre.update_columns(pin_approximate: true)
    expect(signature(lead).find { |item| item[0] == at_centre.id }[3]).to be_nil

    lead.update!(near_lat: nil, near_lng: nil, near_label: nil)
    lead.lead_projects.create!(project: stand_in, firm:)
    property = create(:property, firm:, typology: two_bhk, city:, locality: kharghar)
    property.update_columns(lat: kharghar.lat, lng: kharghar.lng, pin_approximate: true)
    visit = create(:lead_visit, lead:, firm:, visited_at: Time.current)
    LeadVisitProperty.create!(lead_visit: visit, property:, firm:)

    anchors = Inventory::LeadAnchors.for([ lead ])[lead.id]
    expect(anchors.map(&:listing_id)).not_to include(stand_in.id, property.id)

    lat, lng = shifted(north_m: 300)
    property.update_columns(pin_approximate: false, lat:, lng:)
    stand_in.update_columns(pin_approximate: false)
    anchored = Inventory::LeadAnchors.for([ lead.reload ])[lead.id].map(&:listing_id)
    expect(anchored).to include(stand_in.id, property.id)
  end
end
