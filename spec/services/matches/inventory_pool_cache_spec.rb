# frozen_string_literal: true

require "rails_helper"

RSpec.describe Matches::InventoryPool do
  let(:firm) { create(:firm) }
  let(:other) { create(:firm, name: "Mehta Estates") }
  let(:city) { create(:city) }
  let(:locality) { create(:locality, city:, name: "Kharghar") }
  let(:home) { create(:typology, name: "2 BHK", code: "2_bhk") }
  let(:shop) { create(:typology, name: "Shop", code: "shop", category: "commercial") }

  before { Current.firm = firm }
  after { Current.reset }

  it "caches marketplace projects and shared properties under the current keys" do
    memory = ActiveSupport::Cache::MemoryStore.new
    allow(Rails).to receive(:cache).and_return(memory)
    catalog = Current.set(firm: nil, firm_scope_bypassed: true) do
      create(:project, :catalog, firm: nil, city:, locality:, name: "Mixed", starting_budget: 4_000_000,
        builder: create(:builder, firm: nil)).tap do |project|
        create(:project_typology, project:, typology: home, starting_price: 9_000_000, starting_carpet_sqft: 700)
        create(:project_typology, project:, typology: shop, starting_price: 4_000_000, area_value: 400, area_unit: "sqft")
      end
    end
    create(:property, firm: other, typology: shop, price: 8_000_000, listed_on_marketplace: true,
      carpet_area_sqft: 400, pre_leased: true, details: { "lease_monthly_rent" => 80_000 },
      city:, locality:)

    described_class.call(locality_ids: [ locality.id ], price_cap: 20_000_000)

    projects_key = "matches/marketplace-projects/v4/#{locality.id}"
    properties_key = "matches/shared-properties/v5/#{locality.id}"
    expect(memory.exist?(projects_key)).to be(true)
    expect(memory.exist?(properties_key)).to be(true)
    expect(memory.exist?("matches/marketplace-projects/v3/#{locality.id}")).to be(false)
    expect(memory.exist?("matches/shared-properties/v4/#{locality.id}")).to be(false)

    project_row = memory.read(projects_key).find { |row| row["id"] == catalog.id }
    expect(project_row["categories"]).to eq(%w[residential commercial])
    expect(project_row["starting_prices"]).to include("residential" => 9_000_000, "commercial" => 4_000_000)
    expect(project_row["offers"].map { |offer| offer["category"] }).to eq(%w[residential commercial])
    expect(project_row["offers"].first).to include("typology_id", "area_sqft", "pre_leased")

    property_row = memory.read(properties_key).first
    expect(property_row["offers"].first).to include(
      "category" => "commercial", "area_sqft" => 400, "pre_leased" => true, "typology_id" => shop.id
    )
  end

  it "drops a booked listing from the next shared-properties read" do
    memory = ActiveSupport::Cache::MemoryStore.new
    allow(Rails).to receive(:cache).and_return(memory)
    listing = create(:property, firm: other, typology: home, price: 8_000_000, listed_on_marketplace: true,
      city:, locality:)

    ids = -> {
      described_class.call(locality_ids: [ locality.id ], price_cap: 20_000_000)[:properties].map(&:id)
    }
    expect(ids.call).to include(listing.id)

    listing.update!(status: "booked")

    expect(ids.call).not_to include(listing.id)
  end

  it "drops an unshared listing from the next pass" do
    memory = ActiveSupport::Cache::MemoryStore.new
    allow(Rails).to receive(:cache).and_return(memory)
    listing = create(:property, firm: other, typology: home, price: 8_000_000, listed_on_marketplace: true,
      city:, locality:)

    ids = -> {
      described_class.call(locality_ids: [ locality.id ], price_cap: 20_000_000)[:properties].map(&:id)
    }
    expect(ids.call).to include(listing.id)

    listing.update!(listed_on_marketplace: false)

    expect(ids.call).not_to include(listing.id)
  end

  it "keeps a private, booked, sold, suspended, or review-demo listing off another firm's pass" do
    suspended = create(:firm, :suspended)
    demo = create(:firm, review_demo: true)
    rows = [
      create(:property, firm: other, typology: home, price: 8_000_000, listed_on_marketplace: false, city:, locality:),
      create(:property, firm: other, typology: home, price: 8_000_000, listed_on_marketplace: true,
        status: "booked", city:, locality:),
      create(:property, firm: other, typology: home, price: 8_000_000, listed_on_marketplace: true,
        status: "sold_out", city:, locality:),
      create(:property, firm: suspended, typology: home, price: 8_000_000, listed_on_marketplace: true, city:, locality:),
      create(:property, firm: demo, typology: home, price: 8_000_000, listed_on_marketplace: true, city:, locality:)
    ]

    ids = described_class.call(locality_ids: [ locality.id ], price_cap: 20_000_000)[:properties].map(&:id)

    expect(ids).not_to include(*rows.map(&:id))
  end

  it "loads shared properties for every locality in one query" do
    memory = ActiveSupport::Cache::MemoryStore.new
    allow(Rails).to receive(:cache).and_return(memory)
    other_place = create(:locality, city:, name: "Panvel")
    create(:property, firm: other, typology: home, price: 8_000_000, listed_on_marketplace: true, city:, locality:)
    create(:property, firm: other, typology: home, price: 9_000_000, listed_on_marketplace: true,
      city:, locality: other_place)
    events = []
    callback = ->(*, payload) { events << payload }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      described_class.call(locality_ids: [ locality.id, other_place.id ], price_cap: 20_000_000)
    end

    shared = events.select { |event|
      sql = event[:sql].to_s
      sql.include?("listed_on_marketplace") && sql.start_with?("SELECT")
    }
    expect(shared.size).to eq(1)
    expect(Array(shared.first[:type_casted_binds]).map(&:to_s)).to include(locality.id, other_place.id)
  end
end
