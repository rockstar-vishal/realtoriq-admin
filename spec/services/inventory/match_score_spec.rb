# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inventory::ConfigurationKey do
  it "treats 2 BHK variants as the same configuration" do
    expect(described_class.call("2 BHK")).to eq("2bhk")
    expect(described_class.call("2BHK Ultima")).to eq("2bhk")
    expect(described_class.call("2 BHK Compact")).to eq("2bhk")
  end

  it "keeps half configurations and 1 RK apart" do
    expect(described_class.call("2.5 BHK")).to eq("2.5bhk")
    expect(described_class.call("2.5 BHK")).not_to eq(described_class.call("2 BHK"))
    expect(described_class.call("1 RK")).to eq("1rk")
    expect(described_class.call("1 RK")).not_to eq(described_class.call("1 BHK"))
  end
end

RSpec.describe Inventory::MatchScore do
  def offer(price, name)
    described_class::Offer.new(price:, name:, key: Inventory::ConfigurationKey.call(name))
  end

  it "gives 50 points at or under budget plus 2 percent" do
    budget = 10_000_000
    expect(described_class.price_points(10_200_000, budget)).to eq(50)
    expect(described_class.price_points(10_200_001, budget)).to eq(30)
  end

  it "steps down at 15 percent and 25 percent, and stops above that" do
    budget = 10_000_000
    expect(described_class.price_points(11_500_000, budget)).to eq(30)
    expect(described_class.price_points(11_500_001, budget)).to eq(20)
    expect(described_class.price_points(12_500_000, budget)).to eq(20)
    expect(described_class.price_points(12_500_001, budget)).to eq(0)
  end

  it "scores a price under the budget as the top tier" do
    expect(described_class.price_points(8_000_000, 10_000_000)).to eq(50)
  end

  it "uses the smart-matched configuration with the best price tier" do
    budget = 10_000_000
    result = described_class.for_offers(
      budget:,
      lead_keys: [ "2bhk" ],
      offers: [
        offer(14_000_000, "3 BHK"),
        offer(12_000_000, "2 BHK Ultima"),
        offer(10_100_000, "2 BHK Compact")
      ]
    )

    expect(result[:configuration]).to eq(20)
    expect(result[:price]).to eq(50)
    expect(result[:matched_configuration]).to eq("2 BHK Compact")
    expect(result[:score]).to eq(100)
  end

  it "scores the closest price when no configuration matches" do
    budget = 10_000_000
    result = described_class.for_offers(
      budget:,
      lead_keys: [ "3bhk" ],
      offers: [
        offer(7_000_000, "1 BHK"),
        offer(12_400_000, "2 BHK")
      ]
    )

    expect(result[:configuration]).to eq(0)
    expect(result[:price]).to eq(20)
    expect(result[:matched_price]).to eq(12_400_000)
    expect(result[:matched_configuration]).to be_nil
  end
end

RSpec.describe Inventory::MatchInventory do
  let(:firm) { create(:firm) }
  let(:city) { create(:city) }
  let(:locality) { create(:locality, city:, name: "Kharghar") }
  let(:other) { create(:locality, city:, name: "Panvel") }
  let(:two_bhk) { create(:typology, name: "2 BHK") }
  let(:ultima) { create(:typology, name: "2BHK Ultima") }
  let(:status) { create(:lead_status, :new_lead) }

  before { Current.firm = firm }
  after { Current.reset }

  def lead_in(*localities)
    create(:lead, firm:, lead_status: status, budget_max: 10_000_000, transaction_type: "sale").tap do |lead|
      lead.typologies << two_bhk
      localities.each { |row| lead.localities << row }
    end
  end

  it "does not list a project in a different locality" do
    lead = lead_in(locality)
    project = create(:project, firm:, city:, locality: other, starting_budget: 9_000_000)
    create(:project_typology, project:, typology: two_bhk, starting_price: 9_000_000)

    expect(described_class.new(lead:).call).to eq([])
  end

  it "matches 2BHK Ultima in the same locality and skips a rental for a sale lead" do
    lead = lead_in(locality)
    project = create(:project, firm:, city:, locality:, starting_budget: 10_100_000)
    create(:project_typology, project:, typology: ultima, starting_price: 10_100_000)
    rental = create(:property, firm:, typology: two_bhk, listing_for: "rent", price: 50_000,
      building: create(:building, firm:, city:, locality:))

    rows = described_class.new(lead:).call
    expect(rows.map { |row| row[:id] }).to eq([ project.id ])
    expect(rows.first[:score]).to eq(100)
    expect(rows.map { |row| row[:id] }).not_to include(rental.id)
  end

  it "matches a rental property for a rent lead and not a sale project" do
    lead = create(:lead, :rent, firm:, lead_status: status, budget_max: 50_000)
    lead.typologies << two_bhk
    lead.localities << locality
    create(:project, firm:, city:, locality:, starting_budget: 10_000_000)
    rental = create(:property, firm:, typology: two_bhk, listing_for: "rent", price: 48_000,
      building: create(:building, firm:, city:, locality:))

    rows = described_class.new(lead:).call
    expect(rows.map { |row| row[:id] }).to eq([ rental.id ])
    expect(rows.first[:kind]).to eq("property")
    expect(rows.first[:score]).to eq(100)
  end
end
