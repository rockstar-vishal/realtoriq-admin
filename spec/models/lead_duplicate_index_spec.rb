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

  it "returns duplicate_lead when only the old index is present" do
    connection = Lead.connection
    connection.remove_index :leads, name: "index_leads_on_firm_type_category_open_identity"
    connection.add_index :leads, [ :firm_id, :transaction_type, :open_identity ],
      unique: true, where: "open_identity IS NOT NULL",
      name: "index_leads_on_firm_type_and_open_identity"

    first = create_lead(mobile: "9820100201", typology: home, category: "residential")
    second = create_lead(mobile: "9820100201", typology: shop, category: "commercial")

    expect(first).to be_ok
    expect(second.error_code).to eq("duplicate_lead")
    expect(second.error_message).to eq("A sale Commercial lead already exists for this number.")
    expect(Lead.unscoped.where(firm:, mobile: "+919820100201").count).to eq(1)
  end
end
