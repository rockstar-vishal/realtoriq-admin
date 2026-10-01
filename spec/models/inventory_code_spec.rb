# frozen_string_literal: true

require "rails_helper"

RSpec.describe InventoryCode do
  let(:firm) { create(:firm, status: :active) }
  let(:builder) { create(:builder) }
  let(:city) { create(:city) }

  before { Current.firm = firm }
  after { Current.reset }

  it "assigns a project code that is not a sequence" do
    first = create(:project, firm:, builder:, city:)
    second = create(:project, firm:, builder:, city:)

    expect(first.code).to match(Project.inventory_code_format)
    expect(second.code).to match(Project.inventory_code_format)
    expect(second.code).not_to eq(first.code)
  end

  it "assigns a property code with its own prefix" do
    property = create(:property, firm:)

    expect(property.code).to match(Property.inventory_code_format)
    expect(property.code).to start_with("H-")
  end

  it "assigns a code to a marketplace project that has no firm" do
    Current.reset
    project = create(:project, :catalog, firm: nil, builder:, city:, external_ref: "PRABC999")

    expect(project.firm_id).to be_nil
    expect(project.code).to match(Project.inventory_code_format)
  end

  it "retries inside a savepoint when the generated code collides" do
    create(:project, firm:, builder:, city:, code: "P-ABCD22")
    allow(Project).to receive(:generate_inventory_code).and_return("P-ABCD22", "P-EFGH33")

    project = create(:project, firm:, builder:, city:)

    expect(project.code).to eq("P-EFGH33")
    expect(Project.where(code: "P-ABCD22").count).to eq(1)
  end
end
