# frozen_string_literal: true

require "rails_helper"

RSpec.describe Lead do
  let(:firm) { create(:firm) }
  let(:shop) { create(:typology, name: "Shop", code: "shop", category: "commercial") }

  before { Current.firm = firm }

  it "keeps category, area, possession and duplicates in step with the configuration" do
    residential = create(:lead, firm:, prefers_pre_leased: true, area_min_value: 400, area_max_value: 800)
    expect(residential.category).to eq("residential")
    expect(residential.prefers_pre_leased).to be(false)
    expect(residential.area_min_value).to be_nil

    commercial = create(:lead, firm:, category: "commercial", prefers_pre_leased: true,
      area_min_value: 400, area_max_value: 800, area_unit: "sqft")
    expect(commercial.prefers_pre_leased).to be(true)
    expect(commercial.area_min_sqft).to eq(400)
    expect(commercial.area_max_sqft).to eq(800)

    rented = create(:lead, :rent, firm:, category: "commercial", prefers_pre_leased: true)
    expect(rented.prefers_pre_leased).to be(false)

    guntha = build(:lead, firm:, category: "commercial", area_unit: "guntha", area_min_value: 2)
    expect(guntha).not_to be_valid

    plot = create(:lead, firm:, category: "land", area_min_value: 2, area_unit: "guntha",
      possession_by: Date.current)
    expect(plot.area_min_sqft).to eq(2_178)
    expect(plot.property_type).to be_nil
    expect(plot.possession_by).to be_nil
    expect(plot.possession_applies?).to be(false)
    expect(plot.ready_possession?).to be(false)

    unordered = build(:lead, firm:, category: "land", area_min_value: 5, area_max_value: 1, area_unit: "guntha")
    expect(unordered).not_to be_valid

    rented_plot = build(:lead, :rent, firm:, category: "land")
    expect(rented_plot).not_to be_valid
    expect(rented_plot.errors.full_messages).to include("Plot & Land can only be listed for sale.")

    home = create(:lead, firm:)
    home.lead_typologies.build(typology: shop)
    expect(home).not_to be_valid
    expect(home.errors.full_messages).to include("Configurations must all be Residential")

    picker = create(:lead, firm:)
    picker.typologies << create(:typology, name: "1 BHK", code: "1_bhk")
    picker.category = "commercial"
    picker.category_from_client = true
    expect(picker).not_to be_valid
    expect(picker.errors.full_messages).to include("Pick configurations from one category.")

    ready = create(:property_type, name: "Ready possession", code: "ready_possession")
    ready_lead = create(:lead, firm:, property_type: ready)
    expect(ready_lead.possession_applies?).to be(true)
    expect(ready_lead.ready_possession?).to be(true)

    other = create(:lead, firm:, mobile: commercial.mobile, category: "residential")
    expect(other).to be_persisted
    duplicate = build(:lead, firm:, mobile: commercial.mobile, category: "commercial")
    expect(duplicate).not_to be_valid
    expect(duplicate.duplicate_open_lead).to eq(commercial)
  end

  it "writes a note and an audit when the category changes" do
    broker = create(:user, firm:)
    Current.user = broker
    Current.admin_user = create(:admin_user)
    lead = create(:lead, firm:)
    lead.category = "commercial"
    lead.lead_typologies.build(typology: shop)

    lead.save!

    note = lead.lead_activities.find_by!(kind: "note")
    expect(note.body).to eq("Requirement changed from Residential to Commercial (Shop).")
    event = AuditEvent.find_by!(action: "lead.category_changed", subject: lead)
    expect(event.metadata).to include("from" => "residential", "to" => "commercial")
    expect(event.actor).to eq(broker)
  end
end
