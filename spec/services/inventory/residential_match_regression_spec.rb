# frozen_string_literal: true

require "rails_helper"

RSpec.describe "residential match regression" do
  include ActiveSupport::Testing::TimeHelpers

  let(:firm) { create(:firm) }
  let(:other_firm) { create(:firm, name: "Mehta Estates") }
  let(:city) { create(:city) }
  let(:locality) { create(:locality, city:, name: "Kharghar") }
  let(:other) { create(:locality, city:, name: "Panvel") }
  let(:two_bhk) { create(:typology, name: "2 BHK", code: "2_bhk") }
  let(:ultima) { create(:typology, name: "2BHK Ultima") }
  let(:three_bhk) { create(:typology, name: "3 BHK", code: "3_bhk") }
  let(:status) { create(:lead_status, :new_lead) }
  let(:ready_type) { create(:property_type, name: "Ready possession") }
  let(:under_type) { create(:property_type, name: "Under construction") }

  before { Current.firm = firm }
  after { Current.reset }

  def sale_lead(property_type, budget: 10_000_000, typology: two_bhk)
    create(:lead, firm:, lead_status: status, budget_max: budget, transaction_type: "sale", property_type:).tap do |lead|
      lead.typologies << typology
      lead.localities << locality
    end
  end

  def project_named(name, price:, typology: two_bhk, possession_on: Date.new(2027, 6, 1))
    create(:project, firm:, city:, locality:, name:, starting_budget: price, possession_on:, possession_label: nil).tap do |project|
      create(:project_typology, project:, typology:, starting_price: price)
    end
  end

  it "keeps the configuration scorer's numbers" do
    budget = 10_000_000
    matched = Inventory::MatchScore.for_offers(
      budget:,
      lead_keys: [ "2bhk" ],
      offers: [
        Inventory::MatchScore::Offer.new(price: 14_000_000, name: "3 BHK", key: "3bhk"),
        Inventory::MatchScore::Offer.new(price: 12_000_000, name: "2 BHK Ultima", key: "2bhk"),
        Inventory::MatchScore::Offer.new(price: 10_100_000, name: "2 BHK Compact", key: "2bhk")
      ]
    )
    missed = Inventory::MatchScore.for_offers(
      budget:,
      lead_keys: [ "3bhk" ],
      offers: [
        Inventory::MatchScore::Offer.new(price: 7_000_000, name: "1 BHK", key: "1bhk"),
        Inventory::MatchScore::Offer.new(price: 12_400_000, name: "2 BHK", key: "2bhk")
      ]
    )

    expect(matched).to include(configuration: 20, fit: 20, area: nil, bonus: 0, price: 50, score: 100, matched_configuration: "2 BHK Compact")
    expect(missed).to include(configuration: 0, fit: 0, area: nil, bonus: 0, price: 20, score: 50, matched_price: 12_400_000, matched_configuration: nil)
  end

  it "orders same-locality projects by score, then name, and skips another locality" do
    lead = sale_lead(under_type)
    project_named("Beta", price: 10_000_000)
    project_named("Alpha", price: 10_000_000)
    project_named("Stretch", price: 11_500_000)
    create(:project, firm:, city:, locality: other, name: "Elsewhere", starting_budget: 9_000_000).tap do |project|
      create(:project_typology, project:, typology: two_bhk, starting_price: 9_000_000)
    end
    create(:property, firm:, typology: two_bhk, price: 10_000_000, building: create(:building, firm:, city:, locality:))

    rows = Inventory::MatchInventory.new(lead:).call

    expect(rows.map { |row| [ row[:name], row[:score], row[:score_breakdown].slice(:location, :price, :configuration, :fit, :area, :bonus) ] }).to eq([
      [ "Alpha", 100, { location: 30, price: 50, configuration: 20, fit: 20, area: nil, bonus: 0 } ],
      [ "Beta", 100, { location: 30, price: 50, configuration: 20, fit: 20, area: nil, bonus: 0 } ],
      [ "Stretch", 80, { location: 30, price: 30, configuration: 20, fit: 20, area: nil, bonus: 0 } ]
    ])
    expect(rows.map { |row| row[:matched_on] }.uniq).to eq([ %w[locality price configuration] ])
  end

  it "matches 2BHK Ultima for a sale lead and a rental only for a rent lead" do
    lead = sale_lead(under_type)
    project = create(:project, firm:, city:, locality:, starting_budget: 10_100_000)
    create(:project_typology, project:, typology: ultima, starting_price: 10_100_000)
    create(:property, firm:, typology: two_bhk, listing_for: "rent", price: 50_000,
      building: create(:building, firm:, city:, locality:))

    rows = Inventory::MatchInventory.new(lead:).call
    expect(rows.map { |row| [ row[:id], row[:score] ] }).to eq([ [ project.id, 100 ] ])

    renter = create(:lead, :rent, firm:, lead_status: status, budget_max: 50_000)
    renter.typologies << two_bhk
    renter.localities << locality
    rental = Property.find_by!(listing_for: "rent")

    rent_rows = Inventory::MatchInventory.new(lead: renter).call
    expect(rent_rows.map { |row| [ row[:id], row[:kind], row[:score] ] }).to eq([ [ rental.id, "property", 100 ] ])
  end

  it "keeps the ready-possession window and the marketplace floor" do
    travel_to Time.find_zone("Asia/Kolkata").local(2026, 9, 15, 12) do
      ready = sale_lead(ready_type)
      soon = project_named("Soon", price: 10_000_000, possession_on: Date.new(2026, 10, 1))
      past = project_named("Past", price: 10_000_000, possession_on: Date.new(2025, 9, 1))
      project_named("Later", price: 10_000_000, possession_on: Date.new(2027, 6, 1))
      listing = create(:property, firm:, typology: two_bhk, price: 10_000_000,
        building: create(:building, firm:, city:, locality:))

      expect(Inventory::MatchInventory.new(lead: ready).call.map { |row| row[:id] }).to contain_exactly(past.id, soon.id, listing.id)

      buyer = sale_lead(ready_type)
      weak = create(:property, firm: other_firm, typology: two_bhk, price: 20_000_000, listed_on_marketplace: true,
        building: create(:building, firm: other_firm, city:, locality:))
      strong = create(:property, firm: other_firm, typology: three_bhk, price: 11_000_000, listed_on_marketplace: true,
        building: create(:building, firm: other_firm, city:, locality:))
      rows = Inventory::MatchInventory.new(lead: buyer).call
      strong_row = rows.find { |row| row[:id] == strong.id }

      expect(strong_row[:score]).to eq(60)
      expect(strong_row[:score_breakdown]).to include(configuration: 0, fit: 0, price: 30, location: 30)
      expect(rows.map { |row| row[:id] }).not_to include(weak.id)
    end
  end
end
