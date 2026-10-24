# frozen_string_literal: true

require "rails_helper"

RSpec.describe "A place on the lead" do
  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active) }
  let(:other_firm) { create(:firm, name: "Mehta Estates", status: :active) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:other_subscription) { create(:subscription, firm: other_firm, plan:) }
  let!(:manager) { create(:user, :manager, firm:) }
  let!(:new_status) { create(:lead_status, :new_lead) }
  let!(:property_type) { create(:property_type) }
  let!(:typology) { create(:typology, name: "2 BHK") }
  let!(:city) { create(:city, name: "Mumbai") }
  let!(:locality) { create(:locality, city:, name: "Worli") }

  def auth(user)
    post "/api/v1/auth/otp", params: { mobile: user.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify", params: { request_id:, code: Notifications::Deliverer.current.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body["access_token"]}" }
  end

  def place(label: "Office", lat: 19.066, lng: 72.869)
    { label:, address: "Bandra Kurla Complex", lat:, lng:, google_place_id: "ChIJoffice" }
  end

  def create_lead(headers, extra = {})
    post "/api/v1/leads", params: {
      name: "Rhea Kapoor", mobile: "9820144210", transaction_type: "sale",
      property_type_id: property_type.id, budget: 10_000_000,
      typology_ids: [ typology.id ], locality_ids: [ locality.id ]
    }.merge(extra), headers:, as: :json
  end

  it "validates the place, clears it with null, and keeps it off the list" do
    headers = auth(manager)
    create_lead(headers, near_place: place(lat: 5))
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "message")).to include("The place must be inside India.")

    create_lead(headers, near_place: place(lat: 19.066, lng: nil))
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "message")).to include("Latitude and longitude are set together")

    create_lead(headers, near_place: place(label: ""))
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "message")).to include("Near label is required")

    create_lead(headers, near_place: place(label: "O" * 41))
    expect(response).to have_http_status(:unprocessable_content)

    create_lead(headers, near_place: place(label: "  Office  "))
    expect(response).to have_http_status(:created)
    lead = response.parsed_body["lead"]
    expect(lead["near_place"]).to include("label" => "Office", "lat" => 19.066, "lng" => 72.869)
    expect(lead["near_place"]).not_to have_key("near_lat")

    get "/api/v1/leads", headers:, as: :json
    card = response.parsed_body["leads"].find { |row| row["id"] == lead["id"] }
    expect(card.keys).not_to include("near_place")

    patch "/api/v1/leads/#{lead["id"]}", params: { near_place: nil }, headers:, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("lead", "near_place")).to be_nil
    stored = Lead.across_firms.find(lead["id"])
    expect(stored.near_label).to be_nil
    expect(stored.near_lat).to be_nil
    expect(stored.near_place_id).to be_nil
  end

  it "is ignored by matching until anchor matching is on, and drives a match after that" do
    headers = auth(manager)
    bare = create(:locality, city:, name: "Bare")
    builder = create(:builder, firm: nil)
    lat, lng = Inventory::Geo.offset(19.05, 73.07, north_m: 1_000)
    Current.set(firm:) do
      project = create(:project, firm:, city:, locality: bare, builder:, name: "Near the office",
        starting_budget: 10_000_000, possession_on: Date.new(2027, 6, 1), lat:, lng:)
      create(:project_typology, project:, typology:, starting_price: 10_000_000)
      project
    end
    create_lead(headers, near_place: place(lat: 19.05, lng: 73.07))
    lead_id = response.parsed_body.dig("lead", "id")

    post "/api/v1/leads/#{lead_id}/matches", headers:, as: :json
    expect(response.parsed_body["matches"].map { |row| row["name"] }).not_to include("Near the office")
    expect(response.parsed_body["anchors"]).to eq([])

    AnchorMatching.enable!
    post "/api/v1/leads/#{lead_id}/matches", headers:, as: :json
    expect(response.parsed_body["matches"].map { |row| row["name"] }).to include("Near the office")
    expect(response.parsed_body["anchors"].first).to include("kind" => "placed", "name" => "Office")
  end

  it "returns the anchor radius from reference, null while the switch is off" do
    headers = auth(manager)
    get "/api/v1/reference", headers:, as: :json
    expect(response.parsed_body.dig("matching", "anchor_radius_m")).to be_nil

    AnchorMatching.enable!
    AnchorMatching.set_radius!(3_000)
    get "/api/v1/reference", headers:, as: :json
    expect(response.parsed_body.dig("matching", "anchor_radius_m")).to eq(3_000)
  end
end
