# frozen_string_literal: true

require "rails_helper"

RSpec.describe Leads::Create do
  let(:firm) { create(:firm, status: :active) }
  let(:actor) { create(:user, :manager, firm:) }
  let!(:status) { create(:lead_status, :new_lead) }
  let!(:property_type) { create(:property_type, name: "Under construction") }
  let!(:home) { create(:typology, name: "2 BHK", code: "2_bhk") }
  let!(:shop) { create(:typology, name: "Shop", code: "shop", category: "commercial") }
  let!(:city) { create(:city) }
  let!(:locality) { create(:locality, city:) }
  let!(:project) { create(:project, firm:, city:, locality:) }

  before { Current.firm = firm }
  after { Current.reset }

  def create_lead(**options)
    attributes = {
      name: "Rhea Kapoor", mobile: "9820100100", transaction_type: "sale",
      property_type_id: property_type.id, budget: 12_000_000
    }.merge(options.delete(:attributes) || {})
    described_class.new(
      firm:, actor:, attributes:,
      typology_ids: options.fetch(:typology_ids, [ home.id ]),
      locality_ids: options.fetch(:locality_ids, [ locality.id ]),
      project_id: options[:project_id],
      copy_project_typologies: options.fetch(:copy_project_typologies, false)
    ).call
  end

  it "turns a race on the new duplicate index into duplicate_lead" do
    existing = create(:lead, firm:, lead_status: status, mobile: "+919820100100",
      transaction_type: "sale", property_type:)
    allow_any_instance_of(Lead).to receive(:duplicate_on_mobile_and_type).and_return(nil, existing)
    allow_any_instance_of(Lead).to receive(:save!).and_raise(
      ActiveRecord::RecordNotUnique.new(
        'duplicate key value violates unique constraint "index_leads_on_firm_type_category_open_identity"'
      )
    )

    result = create_lead

    expect(result.error_code).to eq("duplicate_lead")
    expect(result.error_message).to eq("A sale Residential lead already exists for this number.")
    expect(result.error_details).to include(lead_id: existing.id, transaction_type: "sale", category: "residential")
  end

  it "resolves the category before the duplicate check" do
    create(:lead, firm:, lead_status: status, mobile: "+919820100100",
      transaction_type: "sale", property_type:)

    mixed = create_lead(typology_ids: [ home.id, shop.id ])

    expect(mixed.error_code).to eq("invalid")
    expect(mixed.error_message).to eq("Pick configurations from one category.")
    expect(Lead.unscoped.where(firm:, mobile: "+919820100100").count).to eq(1)
  end

  it "copies one category, and only its distinct configurations" do
    create(:project_typology, project:, typology: home, label: nil, starting_price: 9_000_000)
    create(:project_typology, project:, typology: home, label: "Ultima", starting_price: 11_000_000)
    create(:project_typology, project:, typology: shop, label: nil, starting_price: 4_000_000)

    homes = create_lead(
      attributes: { mobile: "9820100101" },
      typology_ids: [], project_id: project.id, copy_project_typologies: true
    )
    shops = create_lead(
      attributes: { mobile: "9820100101", category: "commercial" },
      typology_ids: [], project_id: project.id, copy_project_typologies: true
    )

    expect(homes).to be_ok
    expect(homes.lead.category).to eq("residential")
    expect(homes.lead.typology_ids).to eq([ home.id ])
    expect(shops).to be_ok
    expect(shops.lead.category).to eq("commercial")
    expect(shops.lead.typology_ids).to eq([ shop.id ])
  end

  it "refuses a category that disagrees with the configurations" do
    result = create_lead(attributes: { category: "commercial" }, typology_ids: [ home.id ])

    expect(result.error_code).to eq("invalid")
    expect(result.error_message).to eq("Pick configurations from one category.")
  end
end
