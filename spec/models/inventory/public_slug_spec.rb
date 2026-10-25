# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inventory::PublicSlug do
  it "saves a name that contains an underscore" do
    project = create(:project, name: "P_Square")

    expect(project.slug).to eq("p-square")
    expect(project.slug).not_to include("_")
  end

  it "saves a home whose title contains an underscore" do
    locality = create(:locality, name: "Powai")
    firm = create(:firm)
    typology = create(:typology, name: "2_BHK")
    Current.firm = firm
    property = create(:property, firm:, city: locality.city, locality:, typology:)

    expect(property.slug).to eq("2-bhk-in-powai")
    expect(property.slug).not_to include("_")
  ensure
    Current.firm = nil
  end

  it "leaves the slug alone when the name changes" do
    project = create(:project, name: "Aurum Vista")
    slug = project.slug

    project.update!(name: "Renamed_Vista")

    expect(project.slug).to eq(slug)
  end
end
