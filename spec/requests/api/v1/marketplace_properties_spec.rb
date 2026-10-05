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

  it "refuses to map a listing once that firm is suspended" do
    other_firm.suspend!(reason: "Payment overdue")
    lead = lead_for(under_type)

    post "/api/v1/leads/#{lead.id}/properties", params: { property_id: listing.id },
      headers: auth(broker), as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "message")).to include("isn't one of this firm's records")
    expect(response.body).not_to include("Sea Face Tower", "Owner is travelling")
    expect(LeadProperty.across_firms.where(lead_id: lead.id)).to be_empty
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
    expect(response.parsed_body["marketplace_matches"]).to eq([])

    get "/api/v1/properties/#{listing.id}/visitors", headers: auth(owner), as: :json
    expect(response.parsed_body["visitors"]).to eq([])
    expect(response.body).not_to include("Secret Client")
  end

  it "shows another firm's matching lead as the firm, with locality and configuration" do
    lead = lead_for(ready_type, name: "Secret Client")

    post "/api/v1/properties/#{listing.id}/lead_matches", headers: auth(owner), as: :json

    expect(response).to have_http_status(:ok)
    row = response.parsed_body["marketplace_matches"].first
    expect(row).to eq(
      "firm_id" => firm.id,
      "firm_name" => "Shah Realty",
      "code" => lead.code,
      "localities" => [ "Worli" ],
      "configurations" => [ "2 BHK" ],
      "marketplace" => true
    )
    expect(response.parsed_body["matches"].map { |match| match["name"] }).not_to include("Secret Client")
    expect(response.body).not_to include("Secret Client")
  end

  it "identifies each firm by id when two firms share a name" do
    lead = lead_for(ready_type, name: "Secret Client")
    twin = create(:firm, status: :active, name: firm.name)
    create(:subscription, firm: twin, plan:)
    twin_user = create(:user, :manager, firm: twin)
    twin_lead = create(:lead, firm: twin, lead_status: new_status, assigned_user: twin_user,
      name: "Other Client", budget_max: 10_000_000, transaction_type: "sale", property_type: ready_type)
    twin_lead.typologies << typology
    twin_lead.localities << locality

    post "/api/v1/properties/#{listing.id}/lead_matches", headers: auth(owner), as: :json

    rows = response.parsed_body["marketplace_matches"]
    expect(rows.map { |row| row["firm_id"] }).to contain_exactly(firm.id, twin.id)
    expect(rows.map { |row| row["code"] }).to contain_exactly(lead.code, twin_lead.code)
    expect(response.body).not_to include("Secret Client", "Other Client")
  end

  it "lets another firm explore only their own leads that clear the marketplace score" do
    shown = lead_for(ready_type, name: "Shown Client")
    lead_for(ready_type, name: "Budget Miss").update!(budget_max: 1_000_000)

    post "/api/v1/properties/#{listing.id}/lead_matches", headers: auth(broker), as: :json

    expect(response).to have_http_status(:ok)
    names = response.parsed_body["matches"].map { |match| match["name"] }
    expect(names).to eq([ "Shown Client" ])
    shown_match = response.parsed_body["matches"].find { |match| match["name"] == "Shown Client" }
    expect(shown_match["mobile"]).to eq(shown.mobile)
    expect(response.parsed_body["marketplace_matches"]).to eq([])
    expect(response.parsed_body["marketplace_firms"]).to eq([])
    expect(response.body).not_to include("Owner is travelling", "Sea-facing", "Budget Miss")
  end

  it "does not let another firm explore a listing that is no longer shared" do
    listing.update!(listed_on_marketplace: false)

    post "/api/v1/properties/#{listing.id}/lead_matches", headers: auth(broker), as: :json

    expect(response).to have_http_status(:not_found)
  end

  it "hides the limited page once the listing is no longer shared" do
    listing.update!(listed_on_marketplace: false)

    get "/api/v1/properties/#{listing.id}/marketplace", headers: auth(broker), as: :json

    expect(response).to have_http_status(:not_found)
  end

  describe "GET /properties/marketplace" do
    def browse(user = broker, **params)
      get "/api/v1/properties/marketplace", params:, headers: auth(user), as: :json
      response.parsed_body
    end

    it "lists another firm's shared available property without the private fields" do
      row = browse["properties"].find { |item| item["id"] == listing.id }

      expect(response).to have_http_status(:ok)
      expect(row["title"]).to eq("2 BHK in Worli")
      expect(row["listing_for"]).to eq("sale")
      expect(row["locality"]).to eq("Worli")
      expect(row["city"]).to eq("Mumbai")
      expect(row.dig("firm", "name")).to eq("Mehta Estates")
      expect(row.dig("firm", "mobile")).to eq(mobile.value)
      expect(row.dig("firm", "whatsapp")).to eq(whatsapp.value)
      expect(row.keys).to contain_exactly(
        "id", "code", "title", "listing_for", "price", "typology", "locality", "city", "firm"
      )
      expect(response.body).not_to include("Sea Face Tower", "12 Sea Face", "Owner is travelling", "Sea-facing")
    end

    it "leaves out own stock, unshared or unavailable listings, and suspended firms" do
      own = create(:property, firm:, typology:, building: create(:building, firm:, city:, locality:))
      hidden = create(:property, firm: other_firm, typology:, listed_on_marketplace: false,
        building: listing.building)
      booked = create(:property, firm: other_firm, typology:, status: "booked", building: listing.building)
      quiet = create(:firm, :suspended, name: "Quiet Realty")
      quiet_listing = create(:property, firm: quiet, typology:,
        building: create(:building, firm: quiet, city:, locality:, name: "Quiet House"))

      ids = browse["properties"].map { |row| row["id"] }

      expect(ids).to include(listing.id)
      expect(ids).not_to include(own.id, hidden.id, booked.id, quiet_listing.id)
    end

    it "searches the firm, locality, city, and configuration, not the building or description" do
      half = create(:typology, name: "2.5 BHK")
      half_listing = create(:property, firm: other_firm, typology: half, building: listing.building)
      rental = create(:property, firm: other_firm, typology:, listing_for: "rent", price: 50_000,
        building: listing.building)

      expect(browse(q: "2bhk")["properties"].map { |row| row["id"] }).to include(listing.id, rental.id)
      expect(browse(q: "2bhk")["properties"].map { |row| row["id"] }).not_to include(half_listing.id)
      expect(browse(q: "worli")["properties"].map { |row| row["id"] }).to include(listing.id)
      expect(browse(q: "mumbai")["properties"].map { |row| row["id"] }).to include(listing.id)
      expect(browse(q: "mehta")["properties"].map { |row| row["id"] }).to include(listing.id)
      expect(browse(q: "seaface")["properties"]).to eq([])
      expect(browse(q: "seafacing")["properties"]).to eq([])
      expect(browse(q: "!!!")["properties"]).to eq([])
    end

    it "does not list a firm's own properties to that firm" do
      expect(browse(owner)["properties"].map { |row| row["id"] }).not_to include(listing.id)
    end
  end
end
