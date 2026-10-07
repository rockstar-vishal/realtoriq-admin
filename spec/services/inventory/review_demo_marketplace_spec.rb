# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Review demo marketplace scope" do
  let(:plan) { create(:plan) }
  let(:demo) { create(:firm, status: :active, review_demo: true, name: "RealtorIQ Demo") }
  let(:other) { create(:firm, status: :active, name: "Mehta Estates") }
  let(:city) { create(:city) }
  let(:locality) { create(:locality, city:, name: "Kharghar") }
  let(:typology) { create(:typology, name: "2 BHK") }
  let(:status) { create(:lead_status, :new_lead) }
  let!(:ready_type) { create(:property_type, name: "Ready possession") }

  after { Current.reset }

  def lead_for(firm)
    create(:lead, firm:, lead_status: status, budget_max: 10_000_000, transaction_type: "sale",
      property_type: ready_type).tap do |lead|
      lead.typologies << typology
      lead.localities << locality
    end
  end

  def shared_property(firm)
    create(:property, firm:, typology:, price: 11_000_000, listed_on_marketplace: true,
      building: create(:building, firm:, city:, locality:, name: "Sea Face"))
  end

  it "does not show another firm's listing to a review demo lead" do
    three_bhk = create(:typology, name: "3 BHK")
    listing = create(:property, firm: other, typology: three_bhk, price: 11_000_000, listed_on_marketplace: true,
      building: create(:building, firm: other, city:, locality:, name: "Sea Face"))
    buyer = create(:firm, status: :active)
    ordinary = lead_for(buyer)
    Current.firm = buyer
    expect(Inventory::MatchInventory.new(lead: ordinary).call.map { |row| row[:id] }).to include(listing.id)

    demo_lead = lead_for(demo)
    Current.firm = demo
    expect(Inventory::MatchInventory.new(lead: demo_lead).call.map { |row| row[:id] }).not_to include(listing.id)
  end

  it "does not show a review demo listing to another firm's lead" do
    listing = shared_property(demo)
    lead = lead_for(other)
    Current.firm = other

    expect(Inventory::MatchInventory.new(lead:).call.map { |row| row[:id] }).not_to include(listing.id)
    expect(Inventory::MarketplaceListings.new(query: "").scope).not_to include(listing)
  end
end
