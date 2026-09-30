# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inventory::PossessionMatch do
  let(:firm) { create(:firm) }

  def project_on(date)
    build(:project, firm:, possession_on: date, possession_label: nil)
  end

  it "treats the current month and the next two as ready, and a past month as under construction" do
    travel_to Time.find_zone("Asia/Kolkata").local(2026, 9, 15, 12) do
      expect(described_class.ready?(project_on(Date.new(2026, 9, 1)))).to be(true)
      expect(described_class.ready?(project_on(Date.new(2026, 11, 1)))).to be(true)
      expect(described_class.ready?(project_on(Date.new(2026, 12, 1)))).to be(false)
      expect(described_class.ready?(project_on(Date.new(2025, 9, 1)))).to be(false)
      expect(described_class.match_label(project_on(Date.new(2025, 9, 1)))).to eq("Sale · Under construction")
    end
  end

  it "treats a Ready label with no date as ready" do
    project = build(:project, firm:, possession_on: nil, possession_label: "Ready")

    expect(described_class.ready?(project)).to be(true)
  end
end

RSpec.describe Inventory::MatchInventory do
  let(:firm) { create(:firm) }
  let(:other_firm) { create(:firm, name: "Mehta Estates") }
  let(:city) { create(:city) }
  let(:locality) { create(:locality, city:, name: "Kharghar") }
  let(:two_bhk) { create(:typology, name: "2 BHK") }
  let(:status) { create(:lead_status, :new_lead) }
  let!(:ready_type) { create(:property_type, name: "Ready possession") }
  let!(:under_type) { create(:property_type, name: "Under construction") }

  before { Current.firm = firm }
  after { Current.reset }

  def sale_lead(property_type, budget: 10_000_000)
    create(:lead, firm:, lead_status: status, budget_max: budget, transaction_type: "sale", property_type:).tap do |lead|
      lead.typologies << two_bhk
      lead.localities << locality
    end
  end

  def own_project(possession_on:, price: 10_000_000, name: "Own Vista")
    create(:project, firm:, city:, locality:, name:, starting_budget: price, possession_on:, possession_label: nil).tap do |project|
      create(:project_typology, project:, typology: two_bhk, starting_price: price)
    end
  end

  it "shows every live project to an under-construction lead and no properties" do
    travel_to Time.find_zone("Asia/Kolkata").local(2026, 9, 15, 12) do
      lead = sale_lead(under_type)
      past = own_project(possession_on: Date.new(2025, 9, 1), name: "Past")
      soon = own_project(possession_on: Date.new(2026, 10, 1), name: "Soon")
      later = own_project(possession_on: Date.new(2027, 6, 1), name: "Later")
      create(:property, firm:, typology: two_bhk, price: 10_000_000,
        building: create(:building, firm:, city:, locality:))

      ids = described_class.new(lead:).call.map { |row| row[:id] }

      expect(ids).to contain_exactly(past.id, soon.id, later.id)
    end
  end

  it "shows a ready lead the sale properties and only the projects inside the window" do
    travel_to Time.find_zone("Asia/Kolkata").local(2026, 9, 15, 12) do
      lead = sale_lead(ready_type)
      soon = own_project(possession_on: Date.new(2026, 10, 1), name: "Soon")
      own_project(possession_on: Date.new(2025, 9, 1), name: "Past")
      own_project(possession_on: Date.new(2027, 6, 1), name: "Later")
      listing = create(:property, firm:, typology: two_bhk, price: 10_000_000,
        building: create(:building, firm:, city:, locality:))

      ids = described_class.new(lead:).call.map { |row| row[:id] }

      expect(ids).to contain_exactly(soon.id, listing.id)
    end
  end

  it "hides a marketplace row that scores 50 and lists one that scores 60" do
    travel_to Time.find_zone("Asia/Kolkata").local(2026, 9, 15, 12) do
      lead = sale_lead(ready_type, budget: 10_000_000)
      three_bhk = create(:typology, name: "3 BHK")
      weak = create(:property, firm: other_firm, typology: two_bhk, price: 20_000_000, listed_on_marketplace: true,
        building: create(:building, firm: other_firm, city:, locality:))
      strong = create(:property, firm: other_firm, typology: three_bhk, price: 11_000_000, listed_on_marketplace: true,
        building: create(:building, firm: other_firm, city:, locality:))

      rows = described_class.new(lead:).call

      expect(rows.map { |row| row[:id] }).to eq([ strong.id ])
      expect(rows.first[:marketplace]).to be(true)
      expect(rows.first[:listed_by]).to eq("Mehta Estates")
      expect(rows.first[:score]).to eq(60)
      expect(weak.id).to be_present
    end
  end

  it "leaves a shared listing out when the owner has turned the switch off" do
    lead = sale_lead(ready_type)
    create(:property, firm: other_firm, typology: two_bhk, price: 10_000_000, listed_on_marketplace: false,
      building: create(:building, firm: other_firm, city:, locality:))

    expect(described_class.new(lead:).call).to eq([])
  end

  it "returns the top 50 unmapped rows and finds a later one by search" do
    lead = sale_lead(under_type)
    projects = Array.new(51) do |index|
      own_project(possession_on: Date.new(2027, 6, 1), name: format("Match %02d", index))
    end

    result = described_class.new(lead:).result
    expect(result[:matches].size).to eq(50)
    expect(result[:truncated]).to be(true)
    expect(result[:matches].map { |row| row[:id] }).not_to include(projects.last.id)

    found = described_class.new(lead:).result(query: "match50")
    expect(found[:matches].map { |row| row[:id] }).to eq([ projects.last.id ])
    expect(found[:truncated]).to be(false)
  end
end
