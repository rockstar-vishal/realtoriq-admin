# frozen_string_literal: true

require "rails_helper"

# Three separate ways an ordinary client mistake used to return a 500 HTML page
# instead of a JSON error. All three were reproduced against staging before the
# fix; none needed a malicious caller.
RSpec.describe "API v1 malformed input" do
  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:user) { create(:user, :manager, firm:) }

  def deliverer = Notifications::Deliverer.current

  def auth
    post "/api/v1/auth/otp", params: { mobile: user.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify", params: { request_id:, code: deliverer.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
  end

  describe "a `device` that isn't an object" do
    # This ran after the code had been verified and consumed, so the 500 also
    # burned the sign-in code and ate one of the three attempts before lockout.
    [ "iPhone 15", %w[a b], 42 ].each do |value|
      it "ignores #{value.class} rather than crashing, and still signs in" do
        post "/api/v1/auth/otp", params: { mobile: user.mobile }, as: :json
        request_id = response.parsed_body["request_id"]

        post "/api/v1/auth/verify",
          params: { request_id:, code: deliverer.last.code, device: value }, as: :json

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["access_token"]).to be_present
      end
    end

    it "still records a device name when one is sent properly" do
      post "/api/v1/auth/otp", params: { mobile: user.mobile }, as: :json
      request_id = response.parsed_body["request_id"]

      post "/api/v1/auth/verify",
        params: { request_id:, code: deliverer.last.code,
                  device: { device_name: "Tanmay iPhone", platform: "ios" } }, as: :json

      expect(response).to have_http_status(:ok)
      expect(AuthSession.across_firms.last.device_name).to eq("Tanmay iPhone")
    end
  end

  describe "a malformed `page`" do
    # `page=0` is what a zero-indexed client sends for its first page, and
    # `page=` is what an unset form field sends.
    %w[0 -1 abc].each do |value|
      it "treats page=#{value.inspect} as the first page" do
        headers = auth
        create(:lead, firm:)

        get "/api/v1/leads", params: { page: value }, headers: headers

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.dig("meta", "page")).to eq(1)
      end
    end

    it "treats an empty page as the first page" do
      headers = auth
      get "/api/v1/leads", params: { page: "" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("meta", "page")).to eq(1)
    end

    it "does not crash when page arrives as an array" do
      headers = auth
      get "/api/v1/leads?page[]=1", headers: headers

      expect(response).to have_http_status(:ok)
    end

    it "applies to every index endpoint, not just leads" do
      headers = auth

      %w[/api/v1/leads /api/v1/projects /api/v1/properties /api/v1/buildings /api/v1/bookings].each do |path|
        get path, params: { page: "0" }, headers: headers
        expect(response).to have_http_status(:ok), "#{path} returned #{response.status} for page=0"
      end
    end

    it "still honours a real page number" do
      headers = auth
      create_list(:lead, 3, firm:)

      get "/api/v1/leads", params: { page: 2, per_page: 2 }, headers: headers

      expect(response.parsed_body.dig("meta", "page")).to eq(2)
    end
  end

  describe "the typology_ids filter" do
    # `.distinct` plus as_worklist's ORDER BY CASE is rejected by Postgres, so
    # this documented filter 500'd on the default sort and worked on every
    # other one.
    it "works on the default sort" do
      headers = auth
      typology = create(:typology)
      lead = create(:lead, firm:)
      lead.lead_typologies.create!(typology:)

      get "/api/v1/leads", params: { typology_ids: [ typology.id ] }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["leads"].map { |l| l["id"] }).to eq([ lead.id ])
    end

    it "works on every sort" do
      headers = auth
      typology = create(:typology)

      %w[worklist recent updated].each do |sort|
        get "/api/v1/leads", params: { typology_ids: [ typology.id ], sort: }, headers: headers
        expect(response).to have_http_status(:ok), "sort=#{sort} returned #{response.status}"
      end
    end

    it "returns a lead once even when it matches several typologies" do
      headers = auth
      a = create(:typology)
      b = create(:typology)
      lead = create(:lead, firm:)
      lead.lead_typologies.create!(typology: a)
      lead.lead_typologies.create!(typology: b)

      get "/api/v1/leads", params: { typology_ids: [ a.id, b.id ] }, headers: headers

      expect(response.parsed_body["leads"].count { |l| l["id"] == lead.id }).to eq(1)
    end
  end

  describe "a NUL byte in a parameter" do
    # Postgres text cannot hold one, and the pg adapter raises ArgumentError the
    # moment it is bound into a query. Every endpoint that searches returned a
    # 500 HTML page for `q=a%00b`. BaseController now removes them for all.
    let(:nul) { 0.chr }

    %w[/api/v1/leads /api/v1/projects /api/v1/properties /api/v1/buildings /api/v1/bookings].each do |path|
      it "does not crash #{path}?q=" do
        get path, params: { q: "a#{nul}b" }, headers: auth

        expect(response).to have_http_status(:ok)
      end
    end

    it "is removed from a text field in a JSON body before it is stored" do
      create(:lead_status, :new_lead) # a lead needs a status to start in
      property_type = create(:property_type)

      post "/api/v1/leads", params: {
        mobile: "9820155501", transaction_type: "sale", property_type_id: property_type.id,
        name: "Yash#{nul}Raheja", notes: "call#{nul} after 6"
      }, headers: auth, as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("lead", "name")).to eq("YashRaheja")
    end

    it "is removed inside nested arrays too" do
      typology = create(:typology)

      get "/api/v1/leads", params: { typology_ids: [ "#{typology.id}#{nul}" ] }, headers: auth

      expect(response).to have_http_status(:ok)
    end
  end
end
