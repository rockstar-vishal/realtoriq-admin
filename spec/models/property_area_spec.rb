# frozen_string_literal: true

require "rails_helper"

RSpec.describe Property do
  let(:firm) { create(:firm) }
  let(:city) { create(:city) }
  let(:locality) { create(:locality, city:, name: "Thane") }

  before { Current.firm = firm }

  it "converts every area unit, keeps the carpet alias, and titles each category" do
    home = create(:typology, name: "2 BHK", code: "2_bhk")
    shop = create(:typology, name: "Shop", code: "shop", category: "commercial")
    office = create(:typology, name: "Office", code: "office", category: "commercial")
    villa = create(:typology, name: "Villa", code: "villa")
    plot = create(:typology, name: "Residential plot", code: "residential_plot", category: "land")
    karjat = create(:locality, city:, name: "Karjat")

    expect(AreaUnits.to_sqft(10, "sqyd")).to eq(90)
    expect(AreaUnits.to_sqft(10, "sqm")).to eq((BigDecimal("10") * BigDecimal("10.7639")).round(0, :half_up).to_i)
    expect(AreaUnits.to_sqft(2, "guntha")).to eq(2_178)
    expect(AreaUnits.to_sqft(BigDecimal("2.5"), "guntha")).to eq(2_723)
    expect(AreaUnits.to_sqft(1, "acre")).to eq(43_560)
    expect(AreaUnits.to_sqft(1, "hectare")).to eq((BigDecimal("107639.104")).round(0, :half_up).to_i)

    carpet = create(:property, firm:, city:, locality:, typology: home, carpet_area_sqft: 690, floor_band: "middle")
    expect(carpet.area_value).to eq(690)
    expect(carpet.area_unit).to eq("sqft")
    expect(carpet.carpet_area_sqft).to eq(690)
    expect(carpet.floor_band).to eq("middle")
    expect(carpet.title).to eq("2 BHK in Thane")

    shop_listing = create(:property, firm:, city:, locality:, typology: shop, floor_band: "higher",
      area_value: 450, area_unit: "sqft", carpet_area_sqft: nil)
    expect(shop_listing.floor_band).to be_nil
    expect(shop_listing.title).to eq("Shop · 450 sq ft in Thane")

    expect(create(:property, firm:, city:, locality:, typology: office, floor_band: "lower").floor_band).to eq("lower")
    expect(create(:property, firm:, city:, locality:, typology: villa, floor_band: "higher").floor_band).to be_nil

    rented = build(:property, firm:, city:, locality: karjat, typology: plot, listing_for: "rent",
      area_value: 2, area_unit: "guntha")
    expect(rented).not_to be_valid
    expect(rented.errors.full_messages).to include("Plot & Land can only be listed for sale.")

    land = create(:property, firm:, city:, locality: karjat, typology: plot, listing_for: "sale",
      area_value: 2, area_unit: "guntha", price: 5_000_000)
    expect(land.carpet_area_sqft).to eq(2_178)
    expect(land.title).to eq("Residential plot · 2 guntha in Karjat")
    expect(land.rate_per_unit).to eq(amount: 2_500_000, unit: "guntha")

    leased = create(:property, firm:, city:, locality:, typology: shop, listing_for: "sale", price: 10_000_000,
      area_value: 500, area_unit: "sqft", pre_leased: true,
      details: { "lease_monthly_rent" => 100_000, "mystery" => 1 })
    expect(leased.details.keys).to eq([ "lease_monthly_rent" ])
    expect(leased.lease_yield_percent).to eq("12")

    bad = build(:property, firm:, city:, locality:, typology: shop, details: { "frontage_ft" => "wide" })
    expect(bad).not_to be_valid
    expect(bad.errors.full_messages.join).to include("Frontage must be a whole number of feet")
  end
end
