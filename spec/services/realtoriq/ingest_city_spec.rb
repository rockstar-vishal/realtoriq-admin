# frozen_string_literal: true

require "rails_helper"

RSpec.describe "LaunchIQ city share" do
  let!(:two_bhk) { create(:typology, name: "2 BHK", code: "2_bhk", bedrooms: 2) }

  def payload(overrides = {})
    {
      event: "upsert",
      pushed_at: "2026-10-28T06:00:00Z",
      project_code: "PRSHELA01",
      project_name: "Tapovan Amour",
      developer_name: "Tapovan",
      company_code: "CL00A1B2C3",
      rera_number: "P51800000099",
      possession_on: "2028-06-30",
      city: "Ahmedabad",
      locality: "Shela",
      rm_name: "Asha Rao",
      rm_contact: "9876543210",
      unit_types: [
        { label: "2 BHK", typology_name: "2BHK", price_min: 8_000_000 }
      ]
    }.merge(overrides)
  end

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

  def stub_google(pin: "Gujarat", city: "Gujarat")
    client = instance_double(Localities::GoogleGeocoder, state_from_pin: pin, state_from_city: city)
    allow(Localities::GoogleGeocoder).to receive(:new).and_return(client)
    client
  end

  it "creates Ahmedabad from the pin, then reuses it" do
    client = stub_google
    created = nil
    with_maps_key do
      expect {
        created = Realtoriq::IngestProject.call(payload(lat: 23.02, lng: 72.50))
      }.to change(City, :count).by(1)
    end

    expect(created).to be_ok
    project = Project.unscoped.find_by!(external_ref: "PRSHELA01")
    city = City.find_by!(name: "Ahmedabad")
    expect(project).to be_from_catalog
    expect(project.status).to eq("active")
    expect(project.city).to eq(city)
    expect(project.locality.name).to eq("Shela")
    expect(city.state).to eq("Gujarat")
    expect(city.state_code).to eq("GJ")
    expect(city).to be_active
    expect(client).to have_received(:state_from_pin).with(23.02, 72.50)
    expect(client).not_to have_received(:state_from_city)

    with_maps_key do
      expect {
        again = Realtoriq::IngestProject.call(payload(project_code: "PRSHELA02", pushed_at: "2026-10-28T07:00:00Z"))
        expect(again).to be_ok
      }.not_to change(City, :count)
    end
    expect(Project.unscoped.find_by!(external_ref: "PRSHELA02").city).to eq(city)
    expect(Localities::GoogleGeocoder).to have_received(:new).once
  end

  it "creates the city from a forward lookup when the share has no pin" do
    client = stub_google
    with_maps_key do
      result = Realtoriq::IngestProject.call(payload)
      expect(result).to be_ok
    end

    expect(City.find_by!(name: "Ahmedabad").state).to eq("Gujarat")
    expect(client).to have_received(:state_from_city).with("Ahmedabad")
    expect(client).not_to have_received(:state_from_pin)
  end

  it "matches an existing city and refuses a name in two states" do
    existing = create(:city, name: "Ahmedabad", state: "Gujarat")

    result = Realtoriq::IngestProject.call(payload)
    expect(result).to be_ok
    expect(Project.unscoped.find_by!(external_ref: "PRSHELA01").city).to eq(existing)

    create(:city, name: "Ahmedabad", state: "Maharashtra")
    refused = Realtoriq::IngestProject.call(payload(project_code: "PRSHELA03"))
    expect(refused).not_to be_ok
    expect(refused.error).to eq("City Ahmedabad matches more than one state")
    expect(Project.unscoped.find_by(external_ref: "PRSHELA03")).to be_nil
    expect(City.where(name: "Ahmedabad").count).to eq(2)
  end

  it "refuses the share and creates nothing when Google has no state" do
    stub_google(pin: nil, city: nil)
    result = nil
    expect {
      with_maps_key do
        result = Realtoriq::IngestProject.call(payload(lat: 23.02, lng: 72.50))
      end
    }.not_to change { [ City.count, Locality.count, Project.unscoped.count ] }

    expect(result).not_to be_ok
    expect(result.error).to eq("City Ahmedabad is not in RealtorIQ, and its state could not be found")
  end

  it "uses the city the other share just created" do
    create(:city, name: "Ahmedabad", state: "Gujarat")
    stub_google
    calls = 0
    allow(City).to receive(:where).and_wrap_original do |method, *args, **kwargs|
      calls += 1
      if calls == 1
        method.call("1 = 0")
      else
        method.call(*args, **kwargs)
      end
    end
    allow(City).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique)

    result = nil
    with_maps_key { result = Realtoriq::IngestProject.call(payload) }

    expect(result).to be_ok
    expect(Project.unscoped.find_by!(external_ref: "PRSHELA01").city.name).to eq("Ahmedabad")
    expect(City.where(name: "Ahmedabad").count).to eq(1)
  end
end
