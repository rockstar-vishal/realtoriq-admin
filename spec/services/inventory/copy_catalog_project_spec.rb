# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inventory::CopyCatalogProject do
  let(:firm) { create(:firm, status: :active) }
  let(:builder) { create(:builder, name: "Lodha") }
  let(:city) { create(:city) }
  # Created before Current.firm is set. FirmScoped would otherwise stamp the
  # marketplace row with the firm and it would stop being a marketplace row.
  let!(:catalog) do
    create(:project, :catalog, firm: nil, name: "Skyline", builder:, city:, external_ref: "PRABC123")
  end

  before { Current.firm = firm }

  it "leaves a same-named project the firm added, and copies under the developer name" do
    own = create(:project, firm:, name: "Skyline", builder:, city:)

    result = described_class.new(catalog:).call

    expect(result).to be_ok
    expect(result.project.id).not_to eq(own.id)
    expect(result.project.name).to eq("Skyline (Lodha)")
    expect(result.project.external_ref).to eq("PRABC123")
    expect(result.project.code).to match(Project.inventory_code_format)
    expect(result.project.code).not_to eq(catalog.reload.code)
    expect(own.reload.external_ref).to be_nil
  end

  it "reuses the firm's copy after the marketplace project is renamed" do
    first = described_class.new(catalog:).call.project
    Project.unscoped.find(catalog.id).update!(name: "Skyline Phase 2")

    second = described_class.new(catalog: Project.unscoped.find(catalog.id)).call

    expect(second).to be_ok
    expect(second.project.id).to eq(first.id)
    expect(Project.unscoped.where(firm_id: firm.id, external_ref: "PRABC123").count).to eq(1)
  end

  it "reuses the copy when the unique index rejects a second insert" do
    existing = described_class.new(catalog:).call.project
    service = described_class.new(catalog:)
    allow(service).to receive(:own_by_code).and_return(nil, existing)
    allow(Project).to receive(:new).and_wrap_original do |method, *args|
      record = method.call(*args)
      allow(record).to receive(:save!).and_raise(
        ActiveRecord::RecordNotUnique.new(
          'duplicate key value violates unique constraint "index_projects_on_firm_source_and_external_ref"'
        )
      )
      record
    end

    result = service.call

    expect(result.project).to eq(existing)
  end
end
