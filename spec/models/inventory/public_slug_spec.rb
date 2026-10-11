# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inventory::PublicSlug do
  it "puts the property code on the path so identical titles stay distinct" do
    locality = create(:locality, name: "Powai")
    building = create(:building, locality:, city: locality.city)
    typology = create(:typology, name: "2 BHK")
    first, second = Array.new(2) { create(:property, firm: building.firm, building:, typology:) }

    expect(first.slug).to eq("2-bhk-in-powai-#{first.code.downcase}")
    expect(second.slug).to eq("2-bhk-in-powai-#{second.code.downcase}")
    expect(first.slug).not_to eq(second.slug)
  end

  it "leaves the slug alone when the title changes" do
    project = create(:project, name: "Aurum Vista")
    slug = project.slug

    project.update!(name: "Renamed Vista")

    expect(project.slug).to eq(slug)
    expect(slug).to end_with("-#{project.code.downcase}")
  end
end
