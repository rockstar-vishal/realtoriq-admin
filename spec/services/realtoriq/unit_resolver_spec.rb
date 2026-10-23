# frozen_string_literal: true

require "rails_helper"

RSpec.describe Realtoriq::UnitResolver do
  before do
    Typology::CANONICAL.each do |row|
      Typology.upsert_canonical!(row, active_on_create: row[:category] == "residential")
    end
  end

  def resolve(typology_name, label: nil, category: nil)
    described_class.call(typology_name:, typology_category: category, label:)
  end

  def code_for(name)
    case name
    when "Shop", "Commercial Shop", "Office", "Warehouse", "Commercial", "Others" then "commercial"
    when "Plot" then "land"
    else "residential"
    end
  end

  # §8.3 table. Duplex, Plot, Commercial and Others are asserted on their own
  # because they flag or read the unit label.
  LAUNCHIQ = {
    "1BHK" => "1 BHK",
    "1.5BHK" => "1.5 BHK",
    "2BHK" => "2 BHK",
    "2.5BHK" => "2.5 BHK",
    "3BHK" => "3 BHK",
    "3.5BHK" => "3.5 BHK",
    "4BHK" => "4 BHK",
    "5BHK" => "5 BHK",
    "1RK" => "1 RK",
    "3BHK Villa" => "3 BHK",
    "5BHK Villa" => "5 BHK",
    "Row House" => "Row house",
    "Studio" => "1 RK",
    "Bungalow" => "Villa",
    "Shop" => "Shop",
    "Commercial Shop" => "Shop",
    "Office" => "Office",
    "Warehouse" => "Warehouse / Godown"
  }.freeze

  it "resolves every current LaunchIQ configuration" do
    LAUNCHIQ.each do |source, expected|
      result = resolve(source, category: code_for(source))

      expect(result.typology.name).to eq(expected), "#{source} resolved to #{result.typology&.name}"
      expect(result.needs_review).to be(false), "#{source} was flagged"
      expect(result.bhk_conflict).to be(false)
    end
  end

  it "sends Duplex to a new inactive home and Plot to a flagged residential plot" do
    duplex = resolve("Duplex", category: "residential")
    plot = resolve("Plot", category: "land")

    expect(duplex.typology.name).to eq("Duplex")
    expect(duplex.typology).not_to be_active
    expect(duplex.typology.category).to eq("residential")
    expect(duplex.typology.category_confirmed_at).to be_nil
    expect(duplex.needs_review).to be(true)
    expect(plot.typology.code).to eq("residential_plot")
    expect(plot.needs_review).to be(true)
  end

  it "reads a generic Commercial from the unit label and flags Others" do
    office = resolve("Commercial", label: "Grade A Boutique Office Spaces", category: "commercial")
    others = resolve("Others", category: "commercial")

    expect(office.typology.code).to eq("office")
    expect(office.needs_review).to be(false)
    expect(others.typology.code).to eq("other_commercial")
    expect(others.needs_review).to be(true)
  end

  it "gives Plot the LaunchIQ category, and lets a BHK beat a type word" do
    commercial_plot = resolve("Plot", category: "commercial")
    land_plot = resolve("Plot", category: "land")
    villa = resolve("3BHK Villa")
    penthouse = resolve("4BHK Penthouse")
    space = resolve("Commercial space")

    expect(commercial_plot.typology.code).to eq("commercial_plot")
    expect(commercial_plot.needs_review).to be(false)
    expect(land_plot.typology.code).to eq("residential_plot")
    expect(land_plot.needs_review).to be(true)
    expect(villa.typology.code).to eq("3_bhk")
    expect(villa.needs_review).to be(false)
    expect(penthouse.typology.code).to eq("4_bhk")
    expect(penthouse.needs_review).to be(false)
    expect(space.typology.code).to eq("other_commercial")
    expect(space.needs_review).to be(true)
  end

  it "lets an alias win, and does not let the LaunchIQ category override it" do
    shop = Typology.find_by!(code: "shop")
    villa = Typology.find_by!(code: "villa")
    ConfigurationAlias.create!(key: Realtoriq::NameKey.call("Kiosk"), typology: shop, source: "review")
    ConfigurationAlias.create!(key: Realtoriq::NameKey.call("3BHK Villa"), typology: villa, source: "review")

    from_label = resolve("3BHK", label: "Kiosk", category: "residential")
    from_name = resolve("3BHK Villa")
    bhk_first = resolve("3BHK Villa", label: "2 BHK")

    expect(from_label.typology).to eq(shop)
    expect(from_label.needs_review).to be(false)
    expect(from_name.typology).to eq(villa)
    expect(bhk_first.typology.code).to eq("2_bhk")
  end

  it "discards a step that disagrees with the LaunchIQ category and falls back" do
    home = resolve("Corner office", category: "residential")
    commercial = resolve("Hotel", category: "commercial")
    missing = resolve("Hotel")
    land = resolve("Farm parcel", category: "land")
    farmhouse = resolve("Farmhouse", category: "residential")
    again = resolve("Farmhouse", category: "residential")

    expect(home.typology.name).to eq("Corner office")
    expect(home.typology.category).to eq("residential")
    expect(home.typology).not_to be_active
    expect(home.needs_review).to be(true)
    expect(commercial.typology.code).to eq("other_commercial")
    expect(commercial.needs_review).to be(true)
    expect(missing.typology.code).to eq("other_commercial")
    expect(land.typology.code).to eq("residential_plot")
    expect(land.needs_review).to be(true)
    expect(farmhouse.typology.name).to eq("Farmhouse")
    expect(farmhouse.typology).not_to be_active
    expect(again.typology).to eq(farmhouse.typology)
  end

  it "matches 1RK and 4.5 BHK, sends 5.5 to 5+ BHK, and does not read 2 & 3 Bed as a BHK" do
    one_rk = resolve("1RK")
    spaced = resolve("1 RK")
    half = resolve("3BHK Villa", label: "4.5 BHK")
    over = resolve("5.5 BHK")
    deck = resolve("2 & 3 Bed")
    kanakia = resolve("Kanakia", category: "residential")

    expect(one_rk.typology.code).to eq("1_rk")
    expect(spaced.typology.code).to eq("1_rk")
    expect(half.typology.code).to eq("4_5_bhk")
    expect(half.needs_review).to be(true)
    expect(half.bhk_conflict).to be(true)
    expect(over.typology.code).to eq("5_plus_bhk")
    expect(deck.typology.code).to eq("other_commercial")
    expect(kanakia.typology.name).to eq("Kanakia")
    expect(kanakia.typology.code).not_to eq("residential_plot")
  end

  it "stops the backfill at steps 3 to 8" do
    expect(described_class.for_backfill("2BHK Ultima").code).to eq("2_bhk")
    expect(described_class.for_backfill("3BHK Villa").code).to eq("3_bhk")
    expect(described_class.for_backfill("4BHK").code).to eq("4_bhk")
    expect(described_class.for_backfill("Commercial")).to be_nil
    expect(described_class.for_backfill("Duplex")).to be_nil
    expect(described_class.for_backfill("Plot")).to be_nil
    expect(described_class.for_backfill("Cold storage")).to be_nil
    expect(Typology.find_by(name: "Duplex")).to be_nil
  end
end
