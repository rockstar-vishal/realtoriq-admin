# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Project price summary" do
  let(:firm) { create(:firm) }
  let(:home) { create(:typology, name: "2 BHK", code: "2_bhk") }
  let(:shop) { create(:typology, name: "Shop", code: "shop", category: "commercial") }

  before { Current.firm = firm }

  it "names each category on a mixed project and keeps a single category on starting budget" do
    mixed = create(:project, firm:, starting_budget: 9_000_000, on_website: true)
    create(:project_typology, project: mixed, typology: home, starting_price: 9_000_000)
    create(:project_typology, project: mixed, typology: shop, starting_price: 4_000_000)
    single = create(:project, firm:, starting_budget: 9_000_000)
    create(:project_typology, project: single, typology: home, starting_price: 12_000_000)

    expect(mixed.price_summary).to eq("Homes from ₹90 L · Commercial from ₹40 L")
    expect(single.price_summary).to eq("From ₹90 L")

    listed = Api::V1::ProjectSerializer.list(mixed)
    expect(listed[:price_summary]).to eq("Homes from ₹90 L · Commercial from ₹40 L")
    expect(listed[:starting_prices]).to include("residential" => 9_000_000, "commercial" => 4_000_000, "land" => nil)
    filtered = Api::V1::ProjectSerializer.list(mixed, category: "commercial")
    expect(filtered[:price_summary]).to eq("Commercial from ₹40 L")
    expect(filtered[:display_starting_price]).to eq(4_000_000)

    card = Sites::Catalog.new(firm).projects.find { |row| row[:name] == mixed.name }
    expect(card[:price_summary]).to eq("Homes from ₹90 L · Commercial from ₹40 L")
  end
end
