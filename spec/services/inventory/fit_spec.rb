# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inventory::Fit do
  let(:firm) { create(:firm) }

  def lead_for(category, **attrs)
    build(:lead, firm:, category:, transaction_type: category == "land" ? "sale" : "rent", property_type: nil, **attrs)
  end

  describe ".area_points" do
    let(:lead) { lead_for("commercial", area_min_sqft: 800, area_max_sqft: 1_200) }

    it "scores 0 when the lead has no range or the listing has no area" do
      blank = lead_for("commercial")
      expect(described_class.area_points(blank, 1_100)).to eq(0)
      expect(described_class.area_points(lead, nil)).to eq(0)
      expect(described_class.area_points(lead, 0)).to eq(0)
      expect(described_class.area_points(lead_for("residential", area_min_sqft: 800, area_max_sqft: 1_200), 1_100)).to eq(0)
    end

    it "gives 20 inside the inner band and 10 inside the outer band" do
      expect(described_class.area_points(lead, 1_100)).to eq(20)
      expect(described_class.area_points(lead, 720)).to eq(20)
      expect(described_class.area_points(lead, 1_320)).to eq(20)
      expect(described_class.area_points(lead, 719)).to eq(10)
      expect(described_class.area_points(lead, 1_500)).to eq(10)
      expect(described_class.area_points(lead, 600)).to eq(10)
      expect(described_class.area_points(lead, 599)).to eq(0)
      expect(described_class.area_points(lead, 1_501)).to eq(0)
    end

    it "treats a missing max as open and a missing min as zero" do
      open_high = lead_for("land", area_min_sqft: 800, area_max_sqft: nil)
      open_low = lead_for("land", area_min_sqft: nil, area_max_sqft: 1_200)

      expect(described_class.area_points(open_high, 50_000)).to eq(20)
      expect(described_class.area_points(open_low, 100)).to eq(20)
    end
  end

  describe ".fallback_price" do
    let(:home) { create(:typology, name: "2 BHK", code: "2_bhk") }
    let(:shop) { create(:typology, name: "Shop", code: "shop", category: "commercial") }
    let(:buyer) { create(:lead, firm:, category: "residential") }

    it "uses the category price on a mixed project and the project budget otherwise" do
      mixed = create(:project, firm:, starting_budget: 4_000_000)
      create(:project_typology, project: mixed, typology: home, starting_price: 9_000_000)
      create(:project_typology, project: mixed, typology: shop, starting_price: 4_000_000)
      single = create(:project, firm:, starting_budget: 9_000_000)
      create(:project_typology, project: single, typology: home, starting_price: 12_000_000)
      unpriced = create(:project, firm:, starting_budget: 4_000_000)
      create(:project_typology, project: unpriced, typology: home, starting_price: nil)
      create(:project_typology, project: unpriced, typology: shop, starting_price: 4_000_000)

      expect(described_class.fallback_price(buyer, mixed)).to eq(9_000_000)
      expect(described_class.fallback_price(buyer, single)).to eq(9_000_000)
      expect(described_class.fallback_price(buyer, unpriced)).to be_nil
      expect(described_class.fallback_price(buyer, nil)).to be_nil
    end
  end

  describe ".possession_applies?" do
    it "is a sale question and skips plot leads" do
      expect(described_class.possession_applies?(build(:lead, firm:, category: "residential", transaction_type: "sale"))).to be(true)
      expect(described_class.possession_applies?(build(:lead, :rent, firm:, category: "commercial"))).to be(false)
      expect(described_class.possession_applies?(build(:lead, firm:, category: "land", transaction_type: "sale", property_type: nil))).to be(false)
    end
  end
end

RSpec.describe Inventory::CandidateRank do
  def decision(band, distance_m: 10)
    described_class::Decision.new(
      location_points: 30, nearby: band != :preferred, near_shortlist: band == :pin,
      group: band == :preferred ? "locality" : "nearby", distance_m:, band:
    )
  end

  it "puts the pre-leased flag immediately after the score in every band" do
    pin = decision(:pin)
    preferred = decision(:preferred, distance_m: 40)
    neighbor = decision(:neighbor, distance_m: 80)

    expect(described_class.sort_key(ranking: false, decision: preferred, score: 100, name: "Beta", pre_leased_first: true))
      .to eq([ -100, 0, "beta" ])
    expect(described_class.sort_key(ranking: true, decision: pin, score: 80, name: "Beta", pre_leased_first: false))
      .to eq([ 0, 10, -80, 1, "beta" ])
    expect(described_class.sort_key(ranking: true, decision: preferred, score: 80, name: "Beta", pre_leased_first: true))
      .to eq([ 1, 0, -80, 0, 40, "beta" ])
    expect(described_class.sort_key(ranking: true, decision: neighbor, score: 80, name: "Beta", pre_leased_first: true))
      .to eq([ 1, 1, 80, -80, 0, "beta" ])
  end
end

RSpec.describe Inventory::MatchScore do
  it "caps the score at 100 after the pre-leased bonus" do
    offer = described_class::Offer.new(price: 1_000_000, name: "Shop", key: "shop", area_sqft: 1_000, pre_leased: true, category: "commercial")
    lead = build(:lead, category: "commercial", prefers_pre_leased: true, area_min_sqft: 800, area_max_sqft: 1_200)
    result = described_class.for_offers(
      budget: 1_000_000, offers: [ offer ], lead_keys: [ "shop" ], fit: :area, bonus: 10, lead:
    )

    expect(result[:location] + result[:price] + result[:fit] + result[:bonus]).to eq(110)
    expect(result[:score]).to eq(100)
    expect(result[:area]).to eq(20)
    expect(result[:configuration]).to be_nil
    expect(described_class.matched_on(result)).to eq(%w[locality price area pre_leased])
  end

  it "keeps a residential breakdown's scored fields and leaves area blank" do
    offer = described_class::Offer.new(price: 10_100_000, name: "2 BHK Compact", key: "2bhk")
    result = described_class.for_offers(budget: 10_000_000, offers: [ offer ], lead_keys: [ "2bhk" ])

    expect(result).to include(
      location: 30, price: 50, configuration: 20, fit: 20, area: nil, bonus: 0,
      score: 100, matched_price: 10_100_000, matched_configuration: "2 BHK Compact"
    )
    expect(described_class.matched_on(result)).to eq(%w[locality price configuration])
  end
end
