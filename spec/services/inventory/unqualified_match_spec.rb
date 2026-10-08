# frozen_string_literal: true

require "rails_helper"

RSpec.describe "unqualified leads are left out of matching" do
  let(:firm) { create(:firm) }
  let(:other_firm) { create(:firm, name: "Mehta Estates") }
  let(:city) { create(:city) }
  let(:locality) { create(:locality, city:, name: "Kharghar") }
  let(:two_bhk) { create(:typology, name: "2 BHK") }
  let(:live_status) { create(:lead_status, :new_lead) }
  let(:dead_status) { create(:lead_status, :dead) }
  let!(:ready_type) { create(:property_type, name: "Ready possession") }
  let(:manager) { create(:user, :manager, firm:) }
  let(:own_listing) do
    create(:property, firm:, typology: two_bhk, price: 10_000_000,
      building: create(:building, firm:, city:, locality:))
  end
  let(:shared_listing) do
    create(:property, firm: other_firm, typology: two_bhk, price: 10_000_000, listed_on_marketplace: true,
      building: create(:building, firm: other_firm, city:, locality:))
  end

  before { Current.firm = firm }
  after { Current.reset }

  def sale_lead(**attrs)
    create(:lead, firm:, lead_status: live_status, budget_max: 10_000_000,
      transaction_type: "sale", property_type: ready_type, **attrs).tap do |lead|
      lead.typologies << two_bhk
      lead.localities << locality
    end
  end

  def inventory_ids(lead)
    Inventory::MatchInventory.new(lead:).call.map { |row| row[:id] }
  end

  def lead_match_ids(property = own_listing)
    Inventory::MatchLeads.new(user: manager, property:).call.map { |row| row[:id] }
  end

  it "matches a dead lead that is not unqualified" do
    listing = own_listing
    shared = shared_listing
    lead = sale_lead(lead_status: dead_status, dead_reason: "Gone quiet", name: "Quiet Buyer")

    expect(inventory_ids(lead)).to include(listing.id)
    rows = Inventory::MatchLeads.new(user: manager, property: listing).call
    row = rows.find { |match| match[:id] == lead.id }
    expect(row).to be_present
    expect(row[:status]).to eq(
      code: "dead", name: "Dead", is_dead: true, is_booked: false
    )

    Current.firm = other_firm
    expect(Inventory::MarketplaceLeadMatches.new(property: shared).call.map { |match| match[:code] })
      .to include(lead.code)
    expect(Inventory::MarketplaceFirms.new(property: shared).call.map { |match| match[:id] })
      .to include(firm.id)
  end

  it "matches a dead lead and a live lead that share a mobile" do
    listing = own_listing
    dead = sale_lead(lead_status: dead_status, dead_reason: "Gone quiet", mobile: "+919800011199", name: "Old Card")
    live = sale_lead(mobile: dead.mobile, name: "New Card")

    expect(lead_match_ids(listing)).to include(dead.id, live.id)
  end

  it "leaves a booked lead out of every matcher" do
    listing = own_listing
    shared = shared_listing
    lead = sale_lead(lead_status: create(:lead_status, :booked), name: "Booked Buyer")

    expect(inventory_ids(lead)).to eq([])
    expect(lead_match_ids(listing)).not_to include(lead.id)

    Current.firm = other_firm
    expect(Inventory::MarketplaceLeadMatches.new(property: shared).call.map { |match| match[:code] })
      .not_to include(lead.code)
    expect(Inventory::MarketplaceFirms.new(property: shared).call.map { |match| match[:id] })
      .not_to include(firm.id)
  end

  it "leaves an unqualified lead out of every matcher" do
    listing = own_listing
    shared = shared_listing
    lead = sale_lead(unqualified: true, name: "Not a buyer")

    expect(inventory_ids(lead)).to eq([])
    expect(lead_match_ids(listing)).not_to include(lead.id)

    Current.firm = other_firm
    expect(Inventory::MarketplaceLeadMatches.new(property: shared).call.map { |match| match[:code] })
      .not_to include(lead.code)
    expect(Inventory::MarketplaceFirms.new(property: shared).call.map { |match| match[:id] })
      .not_to include(firm.id)
  end

  it "leaves an unqualified dead lead out of every matcher" do
    listing = own_listing
    shared = shared_listing
    lead = sale_lead(lead_status: dead_status, dead_reason: "Wrong number", unqualified: true, name: "Junk")

    expect(inventory_ids(lead)).to eq([])
    expect(lead_match_ids(listing)).not_to include(lead.id)

    Current.firm = other_firm
    expect(Inventory::MarketplaceLeadMatches.new(property: shared).call).to eq([])
    expect(Inventory::MarketplaceFirms.new(property: shared).call).to eq([])
  end
end
