# frozen_string_literal: true

require "rails_helper"
require "mustache"

RSpec.describe Inventory::StreetAddress do
  let(:maps_url) { "https://www.google.com/maps/place/PSK+AURA/@19.0819305,72.86,17z?entry=ttu" }

  describe ".street_address" do
    it "keeps a street address" do
      expect(described_class.street_address("  Off Ghodbunder Road, Kolshet ")).to eq("Off Ghodbunder Road, Kolshet")
    end

    it "drops a blank address" do
      expect(described_class.street_address("  ")).to be_nil
      expect(described_class.street_address(nil)).to be_nil
    end

    it "drops a maps link and any other URL stored as the address" do
      expect(described_class.street_address(maps_url)).to be_nil
      expect(described_class.street_address("maps.app.goo.gl/AbCdEf")).to be_nil
      expect(described_class.street_address("www.google.com/maps/place/PSK+AURA/@19.08")).to be_nil
      expect(described_class.street_address("https://cdn.example.com/brochure.pdf")).to be_nil
    end
  end

  describe ".maps_link" do
    it "returns a maps link, adding a scheme when the paste left it off" do
      expect(described_class.maps_link(maps_url)).to eq(maps_url)
      expect(described_class.maps_link("maps.app.goo.gl/AbCdEf")).to eq("https://maps.app.goo.gl/AbCdEf")
      expect(described_class.maps_link("goo.gl/maps/AbCdEf")).to eq("https://goo.gl/maps/AbCdEf")
    end

    it "does not turn a street address or a brochure link into a map link" do
      expect(described_class.maps_link("12 Sea Face")).to be_nil
      expect(described_class.maps_link("https://cdn.example.com/brochure.pdf")).to be_nil
    end
  end

  it "does not publish a maps link as the public street address" do
    project = create(:project, address: maps_url, lat: 19.08, lng: 72.86, on_website: true)
    listing = Sites::Catalog.new(project.firm).show_project(project)

    expect(listing[:address]).to be_nil
    expect(listing[:map_url]).to be_nil

    project.update_columns(lat: nil, lng: nil)
    bare = Sites::Catalog.new(project.firm).show_project(project.reload)
    expect(bare[:address]).to be_nil
    expect(bare[:map_url]).to eq(maps_url)

    project.update_columns(address: "Harbour Road")
    street = Sites::Catalog.new(project.firm).show_project(project.reload)
    expect(street[:address]).to eq("Harbour Road")
    expect(street[:map_url]).to be_nil
  end

  it "leaves a maps link out of the microsite kit address" do
    project = create(:project, address: maps_url, lat: 19.08, lng: 72.86)
    data = kit_data(project)
    expect(data.dig("project", "address")).to be_nil
    expect(data.dig("project", "map_url")).to eq("https://www.google.com/maps?q=#{project.lat},#{project.lng}")
    expect(kit_html(data)).not_to include("PSK+AURA")
    expect(kit_html(data)).to include("Open in Google Maps")

    project.update_columns(lat: nil, lng: nil, address: "12 Sea Face")
    kept = kit_data(project.reload)
    expect(kept.dig("project", "address")).to eq("12 Sea Face")
    expect(kept.dig("project", "map_url")).to be_nil
    expect(kit_html(kept)).to include("12 Sea Face")
  end

  def kit_data(project)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "assets"))
      Marketing::KitData.new(project, project.firm, dir).to_h
    end
  end

  def kit_html(data)
    Mustache.render(Marketing::KitData::TEMPLATE_ROOT.join("index.html").read, data)
  end
end
