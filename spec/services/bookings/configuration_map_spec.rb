# frozen_string_literal: true

require "rails_helper"

RSpec.describe Bookings::ConfigurationMap do
  let(:firm) { create(:firm) }
  let(:typology) { create(:typology, name: "2 BHK") }
  let(:source_project) { create(:project, firm:) }
  let(:target) { create(:project, firm:) }
  let(:source) { create(:project_typology, project: source_project, typology:, label: "Ultima") }

  before { Current.firm = firm }

  it "matches the copy by typology and label, ignoring case" do
    match = create(:project_typology, project: target, typology:, label: "ultima")

    mapped = described_class.call(typology_id: source.id, source_project_id: source_project.id, project: target)

    expect(mapped).to eq(match.id)
  end

  it "returns nothing when the copy has no matching configuration" do
    create(:project_typology, project: target, typology:, label: "Other")

    mapped = described_class.call(typology_id: source.id, source_project_id: source_project.id, project: target)

    expect(mapped).to be_nil
  end
end
