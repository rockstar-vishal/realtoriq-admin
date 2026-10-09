# frozen_string_literal: true

require "rails_helper"

RSpec.describe Localities::GeocodeCenters do
  let(:city) { create(:city, name: "Mumbai") }
  let(:firm) { create(:firm) }
  let(:builder) { create(:builder, firm: nil) }

  before { Current.firm = firm }
  after { Current.reset }

  def client_for(answers)
    Class.new do
      def initialize(answers)
        @answers = answers
      end

      def coordinates(address)
        raise "unexpected address #{address}" unless @answers.key?(address)

        @answers[address]
      end
    end.new(answers)
  end

  it "fills blanks, keeps a hand-set center, and rebuilds each city once" do
    napean = create(:locality, city:, name: "Napean Sea Road")
    kharghar = create(:locality, city:, name: "Kharghar")
    hand = create(:locality, city:, name: "Bandra West", lat: 19.06, lng: 72.83)
    answers = {
      "Nepean Sea Road, Maharashtra, India" => [ 18.954, 72.800 ],
      "Kharghar, Maharashtra, India" => [ 19.047, 73.069 ]
    }

    expect(Inventory::RebuildLocalityNeighbors).to receive(:call).once.and_call_original
    described_class.call(client: client_for(answers))

    expect(napean.reload.lat.to_f).to eq(18.954)
    expect(kharghar.reload.lng.to_f).to eq(73.069)
    expect(hand.reload.lat.to_f).to eq(19.06)
    expect(LocalityNeighbor.where(locality: napean)).to be_none
  end

  it "leaves the center blank when the geocode is outside Maharashtra" do
    locality = create(:locality, city:, name: "Kharghar")

    described_class.call(client: client_for("Kharghar, Maharashtra, India" => [ 28.6, 77.2 ]))

    expect(locality.reload.lat).to be_nil
  end

  it "leaves the center blank when inventory pins disagree by more than 5 km" do
    locality = create(:locality, city:, name: "Kharghar")
    pin = Inventory::Geo.offset(19.047, 73.069, north_m: 8_000)
    3.times do |index|
      create(:project, firm:, city:, locality:, builder:, name: "Pin #{index}", lat: pin[0], lng: pin[1],
        possession_on: Date.new(2027, 6, 1), possession_label: nil)
    end

    expect {
      described_class.call(client: client_for("Kharghar, Maharashtra, India" => [ 19.047, 73.069 ]))
    }.to output(/review Kharghar, Mumbai: geocode 19.047,73.069 inventory /).to_stdout
    expect(locality.reload.lat).to be_nil
  end

  it "rejects a center outside Maharashtra and a lat without a lng" do
    locality = create(:locality, city:, name: "Kharghar")

    expect(locality.update(lat: 1, lng: 1)).to be(false)
    expect(locality.errors[:lat]).to include("must be inside Maharashtra")
    locality.reload
    expect(locality.update(lat: 19.0, lng: nil)).to be(false)
    expect(locality.errors[:lat]).to include("and longitude are set together")
  end
end

RSpec.describe Localities::GoogleGeocoder do
  it "returns the first result and swallows a failed response without exposing the request" do
    body = { results: [ { geometry: { location: { lat: 19.0, lng: 73.0 } } } ] }.to_json
    ok = Net::HTTPOK.new("1.1", "200", "OK")
    allow(ok).to receive(:body).and_return(body)
    http = instance_double(Net::HTTP)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:request).and_return(ok)
    allow(Net::HTTP).to receive(:start) { |*_args, **_kwargs, &block| block.call(http) }

    coords = described_class.new("test-geocoding-key").coordinates("Kharghar, Maharashtra, India")

    expect(coords).to eq([ 19.0, 73.0 ])
    expect(http).to have_received(:open_timeout=).with(described_class::OPEN_TIMEOUT)
    expect(http).to have_received(:read_timeout=).with(described_class::READ_TIMEOUT)
    expect(http).to have_received(:request) { |req| expect(req.path).to include("address=Kharghar") }

    denied = Net::HTTPUnauthorized.new("1.1", "401", "Unauthorized")
    allow(http).to receive(:request).and_return(denied)
    expect(described_class.new("test-geocoding-key").coordinates("Kharghar, Maharashtra, India")).to be_nil

    allow(Net::HTTP).to receive(:start).and_raise(SocketError, "key=test-geocoding-key")
    expect(described_class.new("test-geocoding-key").coordinates("Kharghar, Maharashtra, India")).to be_nil
  end
end
