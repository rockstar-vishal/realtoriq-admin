# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 inventory" do
  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:user) { create(:user, :super_admin, firm:) }
  let!(:agent) { create(:user, firm:, role: :agent) }

  let(:city) { create(:city) }
  let(:locality) { create(:locality, city:) }
  let(:builder) { create(:builder, firm: nil) }
  let(:typology) { create(:typology, name: "2 BHK") }

  def auth(as: user)
    post "/api/v1/auth/otp", params: { mobile: as.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify", params: { request_id:, code: deliverer.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
  end

  describe "builders" do
    it "lists the global set plus the firm's own" do
      global = create(:builder, firm: nil, name: "Platform Developers")
      mine = create(:builder, firm:, name: "My Developers")
      create(:builder, firm: create(:firm), name: "Someone Else's")

      get "/api/v1/builders", headers: auth

      names = response.parsed_body["builders"].map { |b| b["name"] }
      expect(names).to include(global.name, mine.name)
      expect(names).not_to include("Someone Else's")
    end

    it "creates one owned by the firm, not the platform" do
      post "/api/v1/builders", params: { name: "Sethi Preferred" }, headers: auth, as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("builder", "global")).to be(false)
      expect(Builder.find_by(name: "Sethi Preferred").firm_id).to eq(firm.id)
    end

    it "lets a firm add a name the platform already uses" do
      # Otherwise a broker is blocked by a global row they can neither see the
      # detail of nor edit.
      create(:builder, firm: nil, name: "Aurum Developers")

      post "/api/v1/builders", params: { name: "Aurum Developers" }, headers: auth, as: :json

      expect(response).to have_http_status(:created)
    end

    it "refuses a duplicate within the same firm" do
      create(:builder, firm:, name: "Sethi Preferred")

      post "/api/v1/builders", params: { name: "Sethi Preferred" }, headers: auth, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "appears in /reference for this firm only" do
      create(:builder, firm:, name: "Firm Only Builder")

      get "/api/v1/reference", headers: auth

      names = response.parsed_body["builders"].map { |b| b["name"] }
      expect(names).to include("Firm Only Builder")
    end
  end

  describe "projects" do
    def create_project(overrides = {})
      post "/api/v1/projects", params: {
        name: "Aurum Vista", builder_id: builder.id, city_id: city.id,
        locality_id: locality.id, starting_budget: 14_200_000,
        possession_on: "2027-12-01", brokerage_percent: 4.5,
        typologies: [
          { typology_id: typology.id, starting_price: 14_200_000, starting_carpet_sqft: 720 }
        ]
      }.merge(overrides), headers: auth, as: :json
    end

    it "creates the project with its typologies in one call" do
      create_project

      expect(response).to have_http_status(:created)
      body = response.parsed_body["project"]
      expect(body["typologies"].size).to eq(1)
      expect(body["price_band"]).to eq("from" => 14_200_000, "to" => 14_200_000)
    end

    it "marks anything created here as the firm's own, not catalog" do
      create_project

      expect(Project.across_firms.last.source).to eq("own")
    end

    it "rolls back entirely when a typology is bad" do
      expect {
        create_project(typologies: [ { typology_id: SecureRandom.uuid, starting_price: 1 } ])
      }.not_to change { Project.across_firms.count }
    end

    it "refuses another firm's private builder" do
      stranger = create(:builder, firm: create(:firm))

      create_project(builder_id: stranger.id)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "filters by budget on any typology" do
      create_project
      post "/api/v1/projects", params: {
        name: "Budget Homes", builder_id: builder.id, city_id: city.id,
        starting_budget: 3_000_000, possession_label: "Ready",
        typologies: [ { typology_id: create(:typology).id, starting_price: 3_000_000 } ]
      }, headers: auth, as: :json

      get "/api/v1/projects", params: { budget_min: 10_000_000 }, headers: auth

      expect(response.parsed_body["projects"].map { |p| p["name"] }).to eq([ "Aurum Vista" ])
    end

    it "omits brokerage from the shareable subset" do
      # What the broker earns is not the client's business.
      create_project
      id = response.parsed_body.dig("project", "id")

      get "/api/v1/projects/#{id}", headers: auth

      body = response.parsed_body["project"]
      expect(body["brokerage_percent"]).to eq(4.5)
      expect(body["shareable"]).not_to have_key("brokerage_percent")
    end

    it "returns 404 for another firm's project" do
      other = create(:project, firm: create(:firm))

      get "/api/v1/projects/#{other.id}", headers: auth

      expect(response).to have_http_status(:not_found)
    end

    it "is visible to every user in the firm, unlike leads" do
      create_project

      get "/api/v1/projects", headers: auth(as: agent)

      expect(response.parsed_body["projects"].size).to eq(1)
    end
  end

  describe "buildings" do
    it "creates one from the design's modal" do
      post "/api/v1/buildings", params: {
        name: "Aurum Heights", city_id: city.id, locality_id: locality.id,
        has_pool: true, has_gym: true
      }, headers: auth, as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("building", "has_pool")).to be(true)
    end

    it "refuses a locality outside the chosen city" do
      elsewhere = create(:locality, city: create(:city))

      post "/api/v1/buildings", params: {
        name: "Nowhere Towers", city_id: city.id, locality_id: elsewhere.id
      }, headers: auth, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "searches by name for the property form's picker" do
      create(:building, firm:, name: "Aurum Heights", city:, locality:)
      create(:building, firm:, name: "Trident Bay Towers", city:, locality:)

      get "/api/v1/buildings", params: { q: "Aurum" }, headers: auth

      expect(response.parsed_body["buildings"].map { |b| b["name"] }).to eq([ "Aurum Heights" ])
    end
  end

  describe "properties" do
    let(:building) { create(:building, firm:, city:, locality:) }

    def create_property(overrides = {})
      post "/api/v1/properties", params: {
        building_id: building.id, typology_id: typology.id, listing_for: "sale",
        price: 11_800_000, carpet_area_sqft: 690, floor_band: "middle",
        description: "Corner flat", confidential_note: "Owner: Mr R. Bhatt"
      }.merge(overrides), headers: auth, as: :json
    end

    it "creates one and derives its title and rate" do
      create_property

      body = response.parsed_body["property"]
      expect(response).to have_http_status(:created)
      expect(body["title"]).to eq("2 BHK in #{locality.name}")
      expect(body["rate_per_sqft"]).to eq(17_101)
    end

    describe "the confidential note" do
      it "is returned on the detail, where the design puts it behind a reveal" do
        create_property
        id = response.parsed_body.dig("property", "id")

        get "/api/v1/properties/#{id}", headers: auth

        expect(response.parsed_body.dig("property", "confidential_note")).to eq("Owner: Mr R. Bhatt")
      end

      it "never appears in a list payload" do
        create_property

        get "/api/v1/properties", headers: auth

        expect(response.parsed_body["properties"].first).not_to have_key("confidential_note")
      end

      it "never appears in the shareable subset" do
        # The client composes share text, so this is the structural guarantee
        # that it cannot reach a client's WhatsApp by accident.
        create_property
        id = response.parsed_body.dig("property", "id")

        get "/api/v1/properties/#{id}", headers: auth

        shareable = response.parsed_body.dig("property", "shareable")
        expect(shareable).not_to have_key("confidential_note")
        expect(shareable.to_s).not_to include("R. Bhatt")
      end
    end

    it "filters by listing type" do
      create_property
      create_property(listing_for: "rent", price: 52_000)

      get "/api/v1/properties", params: { listing_for: "rent" }, headers: auth

      expect(response.parsed_body["properties"].size).to eq(1)
      expect(response.parsed_body["properties"].first["price"]).to eq(52_000)
    end

    it "filters by price range" do
      create_property
      create_property(price: 50_000_000)

      get "/api/v1/properties", params: { price_max: 20_000_000 }, headers: auth

      expect(response.parsed_body["properties"].size).to eq(1)
    end

    it "filters by locality through the building" do
      create_property

      get "/api/v1/properties", params: { locality_id: locality.id }, headers: auth
      expect(response.parsed_body["properties"].size).to eq(1)

      get "/api/v1/properties", params: { locality_id: create(:locality).id }, headers: auth
      expect(response.parsed_body["properties"].size).to eq(0)
    end

    it "returns 404 for another firm's property" do
      other_firm = create(:firm)
      other = create(:property, firm: other_firm,
        building: create(:building, firm: other_firm), typology:)

      get "/api/v1/properties/#{other.id}", headers: auth

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "photos" do
    let(:building) { create(:building, firm:, city:, locality:) }
    let(:property) { create(:property, firm:, building:, typology:) }

    # The real flow is: ticket → client PUTs the file to storage → attach.
    # Skipping the middle step leaves a blob record with no file behind it, so
    # the spec does what the client would.
    def signed_id_for(purpose: "property_photo", upload: true)
      post "/api/v1/uploads", params: {
        purpose:, filename: "photo.png", byte_size: 11,
        checksum: "XrY7u+Ae7tCTyyK7j1rNww==", content_type: "image/png"
      }, headers: auth, as: :json

      signed_id = response.parsed_body["signed_id"]

      if upload
        blob = ActiveStorage::Blob.find_signed!(signed_id)
        ActiveStorage::Blob.service.upload(blob.key, StringIO.new("hello world"))
      end

      signed_id
    end

    it "attaches an upload and reports it as the cover" do
      post "/api/v1/properties/#{property.id}/photos",
        params: { photo_signed_ids: [ signed_id_for ] }, headers: auth, as: :json

      expect(response).to have_http_status(:created)
      body = response.parsed_body["property"]
      expect(body["photo_count"]).to eq(1)
      expect(body["cover_photo_url"]).to be_present
    end

    it "refuses a signed_id that doesn't verify" do
      post "/api/v1/properties/#{property.id}/photos",
        params: { photo_signed_ids: [ "not-a-signed-id" ] }, headers: auth, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("invalid_upload")
    end

    it "reports an unfinished upload as a 422, not a 500" do
      # Ticket issued, file never sent — a client whose PUT failed.
      post "/api/v1/properties/#{property.id}/photos",
        params: { photo_signed_ids: [ signed_id_for(upload: false) ] },
        headers: auth, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("upload_incomplete")
    end

    it "refuses an empty request rather than silently doing nothing" do
      post "/api/v1/properties/#{property.id}/photos",
        params: { photo_signed_ids: [] }, headers: auth, as: :json

      expect(response).to have_http_status(:bad_request)
    end

    # Sourced from the response, not from property.photos.attachments — an
    # earlier version of this spec read the id off the model, which is a door
    # the API never opened. It passed while DELETE was uncallable by any real
    # client, because the test knew something no client could learn.
    it "detaches a photo, addressed by the id the API handed back" do
      headers = auth
      post "/api/v1/properties/#{property.id}/photos",
        params: { photo_signed_ids: [ signed_id_for ] }, headers: headers, as: :json

      attachment_id = response.parsed_body.dig("property", "photos", 0, "id")
      expect(attachment_id).to be_present

      delete "/api/v1/properties/#{property.id}/photos/#{attachment_id}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("property", "photo_count")).to eq(0)
      expect(response.parsed_body.dig("property", "photos")).to eq([])
    end

    it "carries the same ids on the detail, so a later visit can still delete" do
      headers = auth
      post "/api/v1/properties/#{property.id}/photos",
        params: { photo_signed_ids: [ signed_id_for ] }, headers: headers, as: :json

      get "/api/v1/properties/#{property.id}", headers: headers

      photos = response.parsed_body.dig("property", "photos")
      expect(photos.length).to eq(1)
      expect(photos.first["id"]).to be_present
      expect(photos.first["url"]).to be_present
      # photo_urls stays alongside it — clients already read that.
      expect(response.parsed_body.dig("property", "photo_urls")).to eq([ photos.first["url"] ])
    end

    it "keeps ids out of the shareable payload, which gets pasted to a client" do
      headers = auth
      post "/api/v1/properties/#{property.id}/photos",
        params: { photo_signed_ids: [ signed_id_for ] }, headers: headers, as: :json

      get "/api/v1/properties/#{property.id}", headers: headers

      shareable = response.parsed_body.dig("property", "shareable")
      expect(shareable).not_to have_key("photos")
      expect(shareable["photo_urls"]).to be_present
    end

    it "does the same for a project" do
      headers = auth
      project = create(:project, firm:, city:, locality:)
      post "/api/v1/projects/#{project.id}/photos",
        params: { photo_signed_ids: [ signed_id_for(purpose: "project_photo") ] },
        headers: headers, as: :json

      attachment_id = response.parsed_body.dig("project", "photos", 0, "id")
      expect(attachment_id).to be_present

      delete "/api/v1/projects/#{project.id}/photos/#{attachment_id}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("project", "photo_count")).to eq(0)
    end

    it "404s on a photo that isn't there" do
      delete "/api/v1/properties/#{property.id}/photos/#{SecureRandom.uuid}", headers: auth

      expect(response).to have_http_status(:not_found)
    end
  end
end
