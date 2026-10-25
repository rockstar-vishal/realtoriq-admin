# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Property location", type: :request do
  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active, name: "Aarav Location") }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:user) { create(:user, :super_admin, firm:) }
  let(:city) { create(:city, name: "Mumbai", state: "Maharashtra") }
  let(:locality) { create(:locality, city:, name: "Kharghar") }
  let(:typology) { create(:typology, name: "2 BHK") }
  let(:ready_type) { create(:property_type, name: "Ready possession") }
  let(:live_status) { create(:lead_status, :new_lead) }

  def auth(as: user)
    post "/api/v1/auth/otp", params: { mobile: as.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify", params: { request_id:, code: deliverer.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
  end

  it "requires a pin on the listing form and not on status, marketplace, or booking" do
    headers = auth
    post "/api/v1/properties", params: {
      building_name: "Sea Face", city_id: city.id, locality_id: locality.id,
      typology_id: typology.id, listing_for: "sale", price: 10_000_000
    }, headers:, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "message")).to include("Place the pin on the map")

    property = create(:property, firm:, typology:, city:, locality:)
    expect(property.has_pin?).to be(false)

    patch "/api/v1/properties/#{property.id}", params: { status: "booked" }, headers:, as: :json
    expect(response).to have_http_status(:ok)
    expect(property.reload.status).to eq("booked")

    patch "/api/v1/properties/#{property.id}", params: { listed_on_marketplace: false }, headers:, as: :json
    expect(response).to have_http_status(:ok)
    expect(property.reload.listed_on_marketplace).to be(false)

    lead = create(:lead, firm:, lead_status: live_status, property_type: ready_type)
    project = create(:project, firm:, city:, locality:, starting_budget: 10_000_000, possession_on: Date.new(2027, 12, 1))
    create(:project_typology, project:, typology:, starting_price: 10_000_000)
    booking = create(:booking, firm:, lead:, project:, unit_no: "A-101")
    expect(booking).to be_persisted
    expect(project.has_pin?).to be(false)

    patch "/api/v1/projects/#{project.id}", params: { status: "archived" }, headers:, as: :json
    expect(response).to have_http_status(:ok)
    expect(project.reload.status).to eq("archived")

    expect(project.save(context: :listing_form)).to be(false)
    expect(project.errors.full_messages.join).to include("Place the pin on the map")

    catalog = create(:project, :catalog, name: "LaunchIQ Pin Exempt", city:, locality:,
      starting_budget: 10_000_000, possession_on: Date.new(2027, 12, 1))
    expect(catalog.save(context: :listing_form)).to be(true)
  end

  it "refuses a pin outside India" do
    property = create(:property, firm:, typology:, city:, locality:, lat: 19.1, lng: 72.8)
    property.lat = 5
    property.lng = 67
    expect(property).not_to be_valid
    expect(property.errors.full_messages.join).to include("The pin must be inside India.")

    property.lat = 6
    property.lng = 68
    expect(property).to be_valid

    project = create(:project, firm:, city:, locality:, lat: 19.1, lng: 72.8, starting_budget: 10_000_000,
      possession_on: Date.new(2027, 12, 1))
    project.lat = 40
    project.lng = 72.8
    expect(project).not_to be_valid
    expect(project.errors.full_messages.join).to include("The pin must be inside India.")
  end

  it "hides the building name, address, and pin from another firm" do
    other = create(:firm, status: :active, name: "Other Estates")
    create(:subscription, firm: other, plan:)
    other_user = create(:user, :super_admin, firm: other)
    property = create(:property, firm:, typology:, city:, locality:, building_name: "SECRET TOWER",
      address: "SECRET ADDRESS", lat: 19.1234567, lng: 72.1234567, listed_on_marketplace: true)

    get "/api/v1/properties/#{property.id}/marketplace", headers: auth(as: other_user)

    expect(response).to have_http_status(:ok)
    raw = response.body
    expect(raw).not_to include("SECRET TOWER")
    expect(raw).not_to include("SECRET ADDRESS")
    expect(raw).not_to include("19.1234567")
    expect(response.parsed_body["property"].keys).not_to include("building_name", "address", "lat", "lng", "google_place_id")

    get "/api/v1/properties/#{property.id}", headers: auth
    detail = response.parsed_body["property"]
    expect(detail["building_name"]).to eq("SECRET TOWER")
    expect(detail["address"]).to eq("SECRET ADDRESS")
    expect(detail["has_pin"]).to be(true)
  end

  it "stores a LaunchIQ pin and copies it onto the firm's project" do
    city
    Typology::CANONICAL.each do |row|
      Typology.upsert_canonical!(row, active_on_create: true)
    end

    result = Realtoriq::IngestProject.call(ingest_payload("PINLOC01", lat: 19.1, lng: 72.8, address: "Harbour Road"))
    catalog = result.project
    expect(catalog.lat.to_f).to eq(19.1)
    expect(catalog.lng.to_f).to eq(72.8)
    expect(catalog.address).to eq("Harbour Road")

    own = create(:project, firm:, city:, builder: catalog.builder, name: "Harbour Copy",
      external_ref: "PINLOC01", source: "own", starting_budget: 10_000_000, possession_on: Date.new(2027, 12, 31))
    expect(own.has_pin?).to be(false)

    Realtoriq::IngestProject.call(
      ingest_payload("PINLOC01", lat: 19.2, lng: 72.9, address: "Harbour Road 2", pushed_at: "2026-10-21T12:00:00Z")
    )
    expect(own.reload.lat.to_f).to eq(19.2)
    expect(own.lng.to_f).to eq(72.9)
    expect(own.address).to eq("Harbour Road 2")

    Realtoriq::IngestProject.call(
      ingest_payload("PINLOC01", lat: 51, lng: 10, address: "Harbour Road 2", pushed_at: "2026-10-22T12:00:00Z")
    )
    expect(catalog.reload.lat.to_f).to eq(19.2)
    expect(own.reload.lat.to_f).to eq(19.2)

    ignored = Realtoriq::IngestProject.call(ingest_payload("PINLOC99", lat: 51, lng: 10))
    expect(ignored.project.lat).to be_nil
    expect(ignored.project.lng).to be_nil
  end

  it "lists missing pins" do
    source = create(:property, firm:, typology:, city:, locality:, lat: 19.3, lng: 72.7,
      address: "Pinned", google_place_id: "ChIJpin")
    sibling = create(:property, firm:, typology:, city:, locality:)
    project = create(:project, firm:, city:, locality:, name: "Unpinned Vista", starting_budget: 8_000_000,
      possession_on: Date.new(2027, 6, 1))
    catalog = create(:project, :catalog, name: "Catalog Unpinned", city:, locality:,
      starting_budget: 8_000_000, possession_on: Date.new(2027, 6, 1))

    missing = rake("locations:missing")
    expect(missing).to include(firm.name, sibling.code, project.code)
    expect(missing).to include("\tproperty", "\tproject")
    expect(missing).not_to include(source.code)
    expect(missing).not_to include(catalog.code)
    expect(sibling.reload.lat).to be_nil
  end

  it "returns locality centres on the reference list" do
    locality.update!(lat: 19.04, lng: 73.06)
    blank = create(:locality, city:, name: "No centre")

    get "/api/v1/reference", headers: auth

    rows = response.parsed_body["localities"]
    placed = rows.find { |row| row["id"] == locality.id }
    empty = rows.find { |row| row["id"] == blank.id }
    expect(placed["lat"]).to eq(19.04)
    expect(placed["lng"]).to eq(73.06)
    expect(empty.keys).to include("lat", "lng")
    expect(empty["lat"]).to be_nil
    expect(empty["lng"]).to be_nil
  end

  it "places an approximate pin at the locality centre, keeps it until the pin moves, and can clear it" do
    headers = auth
    locality.update!(lat: 19.04, lng: 73.06)
    blank = create(:locality, city:, name: "No centre yet")
    property = create(:property, firm:, typology:, city:, locality:)
    project = create(:project, firm:, city:, locality:, name: "Unpinned Vista", starting_budget: 8_000_000,
      possession_on: Date.new(2027, 6, 1))
    skipped = create(:property, firm:, typology:, city:, locality: blank)
    kept = create(:property, firm:, typology:, city:, locality:, lat: 19.2, lng: 72.9)
    stamp = property.updated_at

    with_dry_run(nil) do
      dry = rake("locations:approximate_pins")
      expect(dry).to start_with("would set\t2\n")
      expect(dry).to include("#{skipped.code}\t#{skipped.title}")
      expect(dry).not_to include(kept.code)
      expect(property.reload.lat).to be_nil
      expect(property.pin_approximate).to be(false)
    end

    with_dry_run("0") do
      written = rake("locations:approximate_pins")
      expect(written).to start_with("set\t2\n")
    end

    property.reload
    project.reload
    expect(property.lat).to eq(locality.lat)
    expect(property.lng).to eq(locality.lng)
    expect(property.pin_approximate).to be(true)
    expect(property.updated_at).to eq(stamp)
    expect(project.pin_approximate).to be(true)
    expect(project.lat).to eq(locality.lat)
    expect(skipped.reload.lat).to be_nil
    expect(kept.reload.pin_approximate).to be(false)
    expect(kept.lat.to_f).to eq(19.2)

    missing = rake("locations:missing")
    unpinned, approximate = missing.split(/^approximate\n/, 2)
    expect(unpinned).to include(skipped.code)
    expect(unpinned).not_to include(property.code)
    expect(approximate).to include(property.code, project.code, "\tproperty", "\tproject")
    expect(approximate).to include("approximate\t2")
    expect(approximate).not_to include(skipped.code)

    get "/api/v1/properties/#{property.id}", headers: headers
    body = response.parsed_body["property"]
    expect(body["pin_approximate"]).to be(true)
    expect(body["lat"]).to eq(19.04)
    expect(body["lng"]).to eq(73.06)

    get "/api/v1/projects/#{project.id}", headers: headers
    detail = response.parsed_body["project"]
    expect(detail["pin_approximate"]).to be(true)
    expect(detail["lat"]).to eq(19.04)

    patch "/api/v1/properties/#{property.id}", params: { description: "Same pin" }, headers:, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("property", "pin_approximate")).to be(true)
    expect(property.reload.pin_approximate).to be(true)

    property.lat = property.lat
    property.lng = property.lng
    property.save!
    expect(property.pin_approximate).to be(true)

    project.update!(address: "Same centre")
    expect(project.reload.pin_approximate).to be(true)

    patch "/api/v1/properties/#{property.id}", params: { lat: 19.05, lng: 73.06 }, headers:, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("property", "pin_approximate")).to be(false)
    expect(property.reload.pin_approximate).to be(false)

    project.update!(lat: locality.lat + 0.01)
    expect(project.reload.pin_approximate).to be(false)

    property.update_columns(lat: locality.lat, lng: locality.lng, pin_approximate: true)
    project.update_columns(lat: locality.lat, lng: locality.lng, pin_approximate: true)
    with_dry_run(nil) do
      expect(rake("locations:clear_approximate_pins")).to eq("would clear\t2\n")
      expect(property.reload.pin_approximate).to be(true)
    end
    with_dry_run("0") do
      expect(rake("locations:clear_approximate_pins")).to eq("cleared\t2\n")
    end
    expect(property.reload.lat).to be_nil
    expect(property.lng).to be_nil
    expect(property.pin_approximate).to be(false)
    expect(project.reload.has_pin?).to be(false)
    expect(project.pin_approximate).to be(false)
  end

  it "publishes no map link for an approximate pin" do
    locality.update!(lat: 19.04, lng: 73.06)
    project = create(:project, firm:, city:, locality:, name: "Site Vista", starting_budget: 8_000_000,
      possession_on: Date.new(2027, 6, 1), lat: 19.04, lng: 73.06, on_website: true)
    project.update_columns(pin_approximate: true)

    listing = Sites::Catalog.new(firm).show_project(project)
    helper = Object.new.extend(Sites::PagesHelper)
    expect(helper.maps_href(listing[:lat], listing[:lng])).to be_nil

    project.update_columns(pin_approximate: false)
    placed = Sites::Catalog.new(firm).show_project(project)
    expect(helper.maps_href(placed[:lat], placed[:lng])).to include("19.0400000")
  end

  def with_dry_run(value)
    previous = ENV.fetch("DRY_RUN", nil)
    if value.nil?
      ENV.delete("DRY_RUN")
    else
      ENV["DRY_RUN"] = value
    end
    yield
  ensure
    if previous.nil?
      ENV.delete("DRY_RUN")
    else
      ENV["DRY_RUN"] = previous
    end
  end

  def ingest_payload(code, lat:, lng:, address: "Harbour Road", pushed_at: "2026-10-20T12:00:00Z")
    {
      event: "upsert",
      pushed_at:,
      project_code: code,
      project_name: "Harbour One #{code}",
      developer_name: "Lodha",
      rera_number: "P51800000001",
      possession_on: "2027-12-31",
      city: "Mumbai",
      address:,
      lat:,
      lng:,
      rm_name: "Asha Rao",
      rm_contact: "9876543210",
      unit_types: [
        { typology_name: "2BHK", label: "2 BHK", price_min: 10_000_000, typology_category: "residential" }
      ]
    }
  end

  def rake(name)
    Rails.application.load_tasks unless Rake::Task.task_defined?(name)
    task = Rake::Task[name]
    task.reenable
    output = StringIO.new
    original = $stdout
    $stdout = output
    task.invoke
    output.string
  ensure
    $stdout = original
  end
end
