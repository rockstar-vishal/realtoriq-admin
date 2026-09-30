# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Shared property marketplace" do
  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active, name: "Shah Realty") }
  let(:other_firm) { create(:firm, status: :active, name: "Mehta Estates") }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:other_subscription) { create(:subscription, firm: other_firm, plan:) }
  let!(:broker) { create(:user, :manager, firm:) }
  let!(:owner) { create(:user, :manager, firm: other_firm) }
  let!(:new_status) { create(:lead_status, :new_lead) }
  let!(:ready_type) { create(:property_type, name: "Ready possession") }
  let!(:under_type) { create(:property_type, name: "Under construction") }
  let(:city) { create(:city, name: "Mumbai", state: "Maharashtra") }
  let(:locality) { create(:locality, city:, name: "Worli") }
  let(:typology) { create(:typology, name: "2 BHK") }
  let!(:mobile) { create(:contact_channel, :mobile, firm: other_firm, value: "+919800011122") }
  let!(:whatsapp) { create(:contact_channel, :whatsapp, firm: other_firm, value: "+919800011133") }
  let!(:listing) do
    create(:property, firm: other_firm, typology:, price: 10_000_000, carpet_area_sqft: 700,
      description: "Sea-facing unit", confidential_note: "Owner is travelling",
      building: create(:building, firm: other_firm, city:, locality:, name: "Sea Face Tower",
        address: "12 Sea Face", lat: 19.0, lng: 72.8))
  end

  def auth(user)
    post "/api/v1/auth/otp", params: { mobile: user.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify", params: { request_id:, code: deliverer.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
  end

  def lead_for(property_type, name: "Secret Client")
    create(:lead, firm:, lead_status: new_status, assigned_user: broker, name:,
      budget_max: 10_000_000, transaction_type: "sale", property_type:).tap do |lead|
      lead.typologies << typology
      lead.localities << locality
    end
  end

  it "shows a safe card and lets the other firm map an under-construction lead" do
    lead = lead_for(under_type)

    get "/api/v1/properties/#{listing.id}/marketplace", headers: auth(broker), as: :json

    expect(response).to have_http_status(:ok)
    body = response.parsed_body["property"]
    expect(body["title"]).to eq("2 BHK in Worli")
    expect(body.dig("firm", "name")).to eq("Mehta Estates")
    expect(body.dig("firm", "mobile")).to eq(mobile.value)
    expect(body.dig("firm", "whatsapp")).to eq(whatsapp.value)
    expect(response.body).not_to include("Sea Face Tower", "12 Sea Face", "Owner is travelling", "Sea-facing")

    post "/api/v1/leads/#{lead.id}/properties", params: { property_id: listing.id },
      headers: auth(broker), as: :json

    expect(response).to have_http_status(:created)
    mapped = response.parsed_body.dig("lead", "mapped_properties", 0, "property")
    expect(mapped["marketplace"]).to be(true)
    expect(mapped["listed_by"]).to eq("Mehta Estates")
    expect(mapped).not_to have_key("building")
  end

  it "refuses to map a rent lead onto a sale listing or a project" do
    rental_lead = create(:lead, :rent, firm:, lead_status: new_status, assigned_user: broker)
    headers = auth(broker)

    post "/api/v1/leads/#{rental_lead.id}/properties", params: { property_id: listing.id },
      headers:, as: :json
    expect(response).to have_http_status(:unprocessable_content)

    project = create(:project, firm:, city:, locality:)
    post "/api/v1/leads/#{rental_lead.id}/projects", params: { project_id: project.id },
      headers:, as: :json
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "tells the listing firm which firm mapped a client, without the client's name" do
    lead = lead_for(under_type, name: "Secret Client")
    post "/api/v1/leads/#{lead.id}/properties", params: { property_id: listing.id },
      headers: auth(broker), as: :json
    expect(response).to have_http_status(:created)

    post "/api/v1/leads/#{lead.id}/visits",
      params: { visited_on: "2026-09-20", property_ids: [ listing.id ] },
      headers: auth(broker), as: :json
    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig("visit", "properties", 0, "building")).to be_nil

    post "/api/v1/properties/#{listing.id}/lead_matches", headers: auth(owner), as: :json

    expect(response).to have_http_status(:ok)
    firms = response.parsed_body["marketplace_firms"]
    expect(firms.map { |row| row["name"] }).to eq([ "Shah Realty" ])
    expect(firms.first.keys).to contain_exactly("id", "name", "mobile", "whatsapp")
    expect(response.body).not_to include("Secret Client")

    get "/api/v1/properties/#{listing.id}/visitors", headers: auth(owner), as: :json
    expect(response.parsed_body["visitors"]).to eq([])
    expect(response.body).not_to include("Secret Client")
  end

  it "hides the limited page once the listing is no longer shared" do
    listing.update!(listed_on_marketplace: false)

    get "/api/v1/properties/#{listing.id}/marketplace", headers: auth(broker), as: :json

    expect(response).to have_http_status(:not_found)
  end
end
