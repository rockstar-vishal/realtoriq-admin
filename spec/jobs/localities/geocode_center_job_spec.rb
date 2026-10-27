# frozen_string_literal: true

require "rails_helper"

RSpec.describe Localities::GeocodeCenterJob do
  let(:ahmedabad) { create(:city, name: "Ahmedabad", state: "Gujarat") }
  let(:mumbai) { create(:city, name: "Mumbai", state: "Maharashtra") }
  let(:firm) { create(:firm) }
  let(:builder) { create(:builder, firm: nil) }

  before { Current.firm = firm }
  after { Current.reset }

  def with_maps_key
    previous = ENV.fetch("GOOGLE_GEOCODING_API_KEY", nil)
    ENV["GOOGLE_GEOCODING_API_KEY"] = "test-geocoding-key"
    yield
  ensure
    if previous.nil?
      ENV.delete("GOOGLE_GEOCODING_API_KEY")
    else
      ENV["GOOGLE_GEOCODING_API_KEY"] = previous
    end
  end

  def without_maps_key
    previous = ENV.fetch("GOOGLE_GEOCODING_API_KEY", nil)
    ENV.delete("GOOGLE_GEOCODING_API_KEY")
    yield
  ensure
    if previous.nil?
      ENV.delete("GOOGLE_GEOCODING_API_KEY")
    else
      ENV["GOOGLE_GEOCODING_API_KEY"] = previous
    end
  end

  def stub_coordinates(answer)
    client = instance_double(Localities::GoogleGeocoder)
    allow(client).to receive(:coordinates).and_return(answer)
    allow(Localities::GoogleGeocoder).to receive(:new).and_return(client)
    client
  end

  it "fills a blank centre" do
    shela = create(:locality, city: ahmedabad, name: "Shela")
    stub_coordinates([ 23.01, 72.46 ])

    with_maps_key { described_class.perform_now(shela.id) }

    expect(shela.reload.lat.to_f).to eq(23.01)
    expect(shela.lng.to_f).to eq(72.46)
  end

  it "leaves a hand-set centre alone" do
    shela = create(:locality, city: ahmedabad, name: "Shela", lat: 23.03, lng: 72.50)
    allow(Localities::GoogleGeocoder).to receive(:new)

    with_maps_key { described_class.perform_now(shela.id) }

    expect(Localities::GoogleGeocoder).not_to have_received(:new)
    expect(shela.reload.lat.to_f).to eq(23.03)
  end

  it "leaves the centre blank and logs when three inventory pins disagree" do
    shela = create(:locality, city: ahmedabad, name: "Shela")
    pin = Inventory::Geo.offset(23.01, 72.46, north_m: 8_000)
    3.times do |index|
      create(:project, firm:, city: ahmedabad, locality: shela, builder:, name: "Pin #{index}",
        lat: pin[0], lng: pin[1], possession_on: Date.new(2027, 6, 1), possession_label: nil)
    end
    stub_coordinates([ 23.01, 72.46 ])

    expect {
      with_maps_key { described_class.perform_now(shela.id) }
    }.to output(/review Shela, Ahmedabad: geocode 23.01,72.46 inventory /).to_stdout
    expect(shela.reload.lat).to be_nil
  end

  it "logs and returns when the key is missing" do
    shela = create(:locality, city: ahmedabad, name: "Shela")
    allow(Localities::GoogleGeocoder).to receive(:new)
    allow(Rails.logger).to receive(:info)

    without_maps_key { described_class.perform_now(shela.id) }

    expect(Rails.logger).to have_received(:info).with("[geocode] key missing, Shela, Ahmedabad left blank")
    expect(Localities::GoogleGeocoder).not_to have_received(:new)
    expect(shela.reload.lat).to be_nil
  end

  it "leaves the centre blank when Google returns nothing" do
    shela = create(:locality, city: ahmedabad, name: "Shela")
    stub_coordinates(nil)

    with_maps_key { described_class.perform_now(shela.id) }

    expect(shela.reload.lat).to be_nil
  end

  it "does nothing when the locality is gone" do
    expect { described_class.perform_now(SecureRandom.uuid) }.not_to raise_error
  end

  it "builds neighbour pairs across cities when anchor matching is on" do
    near = Inventory::Geo.offset(23.01, 72.46, north_m: 2_000)
    other = create(:locality, city: mumbai, name: "Andheri", lat: near[0], lng: near[1])
    shela = create(:locality, city: ahmedabad, name: "Shela")
    stub_coordinates([ 23.01, 72.46 ])
    AnchorMatching.enable!

    with_maps_key { described_class.perform_now(shela.id) }

    expect(LocalityNeighbor.where(locality_id: shela.id, neighbor_locality_id: other.id)).to exist
    expect(LocalityNeighbor.where(locality_id: other.id, neighbor_locality_id: shela.id)).to exist
  end
end
