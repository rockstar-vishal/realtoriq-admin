# frozen_string_literal: true

require "rails_helper"

RSpec.describe "open lead index during the category release" do
  let(:firm) { create(:firm, status: :active) }
  let(:actor) { create(:user, :manager, firm:) }
  let!(:status) { create(:lead_status, :new_lead) }
  let!(:property_type) { create(:property_type, name: "Under construction") }
  let!(:home) { create(:typology, name: "2 BHK", code: "2_bhk") }
  let!(:shop) { create(:typology, name: "Shop", code: "shop", category: "commercial") }
  let!(:locality) { create(:locality) }

  before { Current.firm = firm }
  after { Current.reset }

  def create_lead(mobile:, typology:, category:)
    Leads::Create.new(
      firm:, actor:,
      attributes: {
        name: "Rhea Kapoor", mobile:, transaction_type: "sale", category:,
        property_type_id: property_type.id, budget: 12_000_000
      },
      typology_ids: [ typology.id ],
      locality_ids: [ locality.id ]
    ).call
  end

  it "saves a second category while the new index is in place" do
    first = create_lead(mobile: "9820100200", typology: home, category: "residential")
    second = create_lead(mobile: "9820100200", typology: shop, category: "commercial")

    expect(first).to be_ok
    expect(second).to be_ok
    expect(second.lead.category).to eq("commercial")
    expect(Lead.unscoped.where(firm:, mobile: "+919820100200").count).to eq(2)
  end
end
