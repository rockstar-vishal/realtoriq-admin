# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectTypology do
  let(:firm) { create(:firm) }
  let(:project) { create(:project, firm:) }
  let(:typology) { create(:typology, name: "2 BHK", code: "2_bhk") }

  before { Current.firm = firm }

  it "allows the same configuration twice when the labels differ, and the index rejects a repeat" do
    create(:project_typology, project:, typology:, label: "Ultima")
    second = create(:project_typology, project:, typology:, label: "Garden")

    expect(second).to be_persisted
    repeat = build(:project_typology, project:, typology:, label: "ultima")
    expect(repeat).not_to be_valid
    expect(repeat.errors.full_messages).to include("A configuration can appear twice only with different labels.")
    expect { repeat.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "stores a label only when it says more than the configuration, and displays it by the contains rule" do
    office = create(:typology, name: "Office", code: "office", category: "commercial")
    villa = create(:typology, name: "Villa", code: "villa")

    boutique = create(:project_typology, project:, typology: office, label: "Grade A Boutique Office Spaces")
    same_villa = create(:project_typology, project:, typology: villa, label: "Villa")
    same_bhk = create(:project_typology, project:, typology:, label: "2BHK")
    ultima = create(:project_typology, project:, typology:, label: "2BHK Ultima")
    short = create(:project_typology, project:, typology:, label: "Ultima")

    expect(boutique.reload.label).to eq("Grade A Boutique Office Spaces")
    expect(boutique.display_name).to eq("Grade A Boutique Office Spaces")
    expect(same_villa.reload.label).to be_nil
    expect(same_villa.display_name).to eq("Villa")
    expect(same_bhk.reload.label).to be_nil
    expect(same_bhk.display_name).to eq("2 BHK")
    expect(ultima.reload.label).to eq("2BHK Ultima")
    expect(ultima.display_name).to eq("2BHK Ultima")
    expect(short.reload.display_name).to eq("2 BHK Ultima")
  end

  it "lets a carpet edit replace the stored area" do
    row = create(:project_typology, project:, typology:, starting_carpet_sqft: 690)
    expect(row.area_value).to eq(690)

    row.update!(starting_carpet_sqft: 750)

    expect(row.area_value).to eq(750)
    expect(row.starting_carpet_sqft).to eq(750)
    expect(row.area_unit).to eq("sqft")
  end
end
