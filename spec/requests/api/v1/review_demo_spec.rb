# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Meta review demo account" do
  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active, review_demo: true, rera_number: "A51800000000") }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:user) { create(:user, :super_admin, firm:, mobile: "+919876754543", email: nil) }

  before do
    @original_fixed_code = Rails.configuration.x.otp_fixed_code
    Rails.configuration.x.otp_fixed_code = nil
    allow(Rails.env).to receive(:production?).and_return(true)
  end

  after do
    Rails.configuration.x.otp_fixed_code = @original_fixed_code
  end

  def request_code(mobile = "9876754543")
    post "/api/v1/auth/otp", params: { mobile: }, as: :json
    response.parsed_body
  end

  def auth_headers_for(person, mobile: person.mobile)
    body = request_code(mobile)
    post "/api/v1/auth/verify",
      params: { request_id: body["request_id"], code: deliverer.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
  end

  describe "sign-in" do
    it "issues the review code without sending anything" do
      allow(SecureRandom).to receive(:random_number).and_call_original
      allow(SecureRandom).to receive(:random_number).with(1_000_000).and_return(424242)
      allow(Rails.logger).to receive(:info).and_call_original

      body = request_code

      expect(response).to have_http_status(:ok)
      expect(body.keys).to include("request_id", "sent_to", "expires_in", "attempts_allowed")
      expect(deliverer.deliveries).to be_empty
      record = OneTimeCode.find(body["request_id"])
      expect(BCrypt::Password.new(record.code_digest)).to eq(Auth::ReviewLogin::CODE)
      expect(Rails.logger).to have_received(:info).with("[auth] review demo code issued")
      expect(Rails.logger).not_to have_received(:info).with(a_string_including(Auth::ReviewLogin::CODE))

      post "/api/v1/auth/verify",
        params: { request_id: body["request_id"], code: Auth::ReviewLogin::CODE }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["access_token"]).to be_present
      audit = AuditEvent.find_by(action: "user.signed_in", subject: user)
      expect(audit.metadata).to include("review_login" => true)
    end

    it "sends a random code when the number belongs to an ordinary firm" do
      user.update!(mobile: "+919820144210")
      ordinary = create(:firm, status: :active)
      create(:subscription, firm: ordinary, plan:)
      create(:user, :super_admin, firm: ordinary, mobile: "+919876754543")
      allow(SecureRandom).to receive(:random_number).and_call_original
      allow(SecureRandom).to receive(:random_number).with(1_000_000).and_return(424242)

      request_code

      expect(response).to have_http_status(:ok)
      expect(deliverer.last.destination).to eq("+919876754543")
      expect(deliverer.last.code).to eq("424242")
    end

    it "sends a random code for any other number" do
      user.update!(mobile: "+919820144210")
      allow(SecureRandom).to receive(:random_number).and_call_original
      allow(SecureRandom).to receive(:random_number).with(1_000_000).and_return(424242)

      request_code("9820144210")

      expect(deliverer.last.code).to eq("424242")
      expect(deliverer.last.destination).to eq("+919820144210")
    end

    it "does not lock the review user out after three wrong codes" do
      body = request_code

      3.times do
        post "/api/v1/auth/verify",
          params: { request_id: body["request_id"], code: "000000" }, as: :json
      end

      expect(user.reload).not_to be_locked_out
      post "/api/v1/auth/verify",
        params: { request_id: body["request_id"], code: Auth::ReviewLogin::CODE }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["access_token"]).to be_present
    end

    it "burns the review code after one success" do
      body = request_code

      2.times do
        post "/api/v1/auth/verify",
          params: { request_id: body["request_id"], code: Auth::ReviewLogin::CODE }, as: :json
      end

      expect(response).to have_http_status(:unauthorized)
    end

    it "expires the review code after ten minutes" do
      body = request_code

      travel 11.minutes do
        post "/api/v1/auth/verify",
          params: { request_id: body["request_id"], code: Auth::ReviewLogin::CODE }, as: :json
      end

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body.dig("error", "code")).to eq("invalid_code")
    end

    it "returns account_suspended when the demo firm is suspended" do
      body = request_code
      firm.suspend!(reason: "Review paused")

      post "/api/v1/auth/verify",
        params: { request_id: body["request_id"], code: Auth::ReviewLogin::CODE }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("account_suspended")
    end

    it "returns subscription_lapsed once the demo subscription has run out" do
      body = request_code
      post "/api/v1/auth/verify",
        params: { request_id: body["request_id"], code: Auth::ReviewLogin::CODE }, as: :json
      headers = { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
      subscription.update!(
        current_period_start: 2.months.ago.to_date,
        current_period_end: Date.yesterday
      )

      get "/api/v1/me", headers: headers

      expect(response).to have_http_status(:payment_required)
      expect(response.parsed_body.dig("error", "code")).to eq("subscription_lapsed")
    end
  end

  describe "guardrails" do
    def sign_in(person = user)
      body = request_code(person.mobile.delete_prefix("+91"))
      code = Auth::ReviewLogin.applies_to?(person) ? Auth::ReviewLogin::CODE : deliverer.last.code
      post "/api/v1/auth/verify", params: { request_id: body["request_id"], code: }, as: :json
      { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
    end

    it "refuses a contact-channel code and still sends one for an ordinary firm" do
      channel = create(:contact_channel, :email, firm:)
      headers = sign_in

      post "/api/v1/firm/contact_channels/#{channel.id}/request_code", headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("demo_account_restricted")
      expect(response.parsed_body.dig("error", "message")).to eq("Not available in the demo account.")
      expect(deliverer.deliveries).to be_empty

      result = Verifications::SendCode.new(channel:).call
      expect(result.ok?).to be(false)
      expect(result.error).to eq("Not available in the demo account.")
      expect(deliverer.deliveries).to be_empty

      ordinary = create(:firm, status: :active)
      create(:subscription, firm: ordinary, plan:)
      owner = create(:user, :super_admin, firm: ordinary)
      ordinary_channel = create(:contact_channel, :email, firm: ordinary)

      post "/api/v1/firm/contact_channels/#{ordinary_channel.id}/request_code", headers: sign_in(owner)

      expect(response).to have_http_status(:ok)
      expect(deliverer.last.destination).to eq(ordinary_channel.value)
    end

    it "refuses a new user and a mobile change, and still allows a name change" do
      headers = sign_in
      agent = create(:user, firm:, name: "Old Name")

      post "/api/v1/users", params: { name: "Extra", mobile: "9820199001", role: "agent" },
        headers:, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("demo_account_restricted")
      expect(firm.users.where(name: "Extra")).to be_empty

      patch "/api/v1/users/#{agent.id}", params: { mobile: "9820199002" }, headers:, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("demo_account_restricted")
      expect(agent.reload.mobile).not_to eq("+919820199002")

      patch "/api/v1/users/#{agent.id}", params: { name: "New Name", notification_mode: "none" },
        headers:, as: :json

      expect(response).to have_http_status(:ok)
      expect(agent.reload.name).to eq("New Name")
      expect(agent.notification_mode).to eq("none")
    end

    it "lets an ordinary firm add a user and change a mobile" do
      ordinary = create(:firm, status: :active)
      create(:subscription, firm: ordinary, plan:)
      owner = create(:user, :super_admin, firm: ordinary)
      agent = create(:user, firm: ordinary)
      headers = sign_in(owner)

      post "/api/v1/users", params: { name: "Priya Mehta", mobile: "9820199001", role: "agent" },
        headers:, as: :json

      expect(response).to have_http_status(:created)

      patch "/api/v1/users/#{agent.id}", params: { mobile: "9820199002" }, headers:, as: :json

      expect(response).to have_http_status(:ok)
      expect(agent.reload.mobile).to eq("+919820199002")
    end

    it "refuses a visit pass for the demo firm and still creates one for an ordinary firm" do
      lead = create(:lead, firm:, name: "Sample")
      headers = sign_in
      calls = 0
      allow(Realtoriq::TurboClient).to receive(:create_visit_pass) do
        calls += 1
        {
          "pass_code" => "CPVPABC123",
          "pass_url" => "https://launch.example/vp/token",
          "address" => "12 Sea Face",
          "rm_name" => "Asha Rao",
          "rm_contact" => "9876543210"
        }
      end

      post "/api/v1/leads/#{lead.id}/visit_passes",
        params: { project_id: "missing", tentative_visit_planned: 2.days.from_now.utc.iso8601 },
        headers:, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("demo_account_restricted")
      expect(calls).to eq(0)

      ordinary = create(:firm, status: :active, rera_number: "A51800000099")
      create(:subscription, firm: ordinary, plan:)
      owner = create(:user, :super_admin, firm: ordinary, rera_number: "A51800000098")
      city = create(:city, name: "Pune", state: "Maharashtra")
      locality = create(:locality, city:, name: "Baner")
      catalog = Current.set(firm: nil, firm_scope_bypassed: true) do
        create(:project, :catalog, firm: nil, external_ref: "PR4F2A9C", name: "Harbour One",
          city:, locality:, starting_budget: 15_000_000)
      end
      ordinary_lead = create(:lead, firm: ordinary, name: "Meera Shah", mobile: "+919876543210")
      ordinary_headers = sign_in(owner)
      post "/api/v1/leads/#{ordinary_lead.id}/projects", params: { project_id: catalog.id },
        headers: ordinary_headers, as: :json
      expect(response).to have_http_status(:created)

      post "/api/v1/leads/#{ordinary_lead.id}/visit_passes",
        params: { project_id: catalog.id, tentative_visit_planned: 2.days.from_now.utc.iso8601 },
        headers: ordinary_headers, as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("visit_pass", "pass_code")).to eq("CPVPABC123")
      expect(calls).to eq(1)
    end
  end

  describe "marketplace" do
    let!(:new_status) { create(:lead_status, :new_lead) }
    let!(:ready_type) { create(:property_type, name: "Ready possession") }
    let(:city) { create(:city, name: "Mumbai", state: "Maharashtra") }
    let(:locality) { create(:locality, city:, name: "Worli") }
    let(:typology) { create(:typology, name: "2 BHK") }
    let(:other_firm) { create(:firm, status: :active, name: "Mehta Estates") }
    let(:witness) { create(:firm, status: :active, name: "Shah Realty") }
    let!(:other_owner) { create(:user, :super_admin, firm: other_firm) }
    let!(:witness_agent) { create(:user, firm: witness) }
    let!(:other_subscription) { create(:subscription, firm: other_firm, plan:) }

    def sign_in(person)
      body = request_code(person.mobile)
      code = Auth::ReviewLogin.applies_to?(person) ? Auth::ReviewLogin::CODE : deliverer.last.code
      post "/api/v1/auth/verify", params: { request_id: body["request_id"], code: }, as: :json
      { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
    end

    def listing_for(owner_firm, name:)
      create(:property, firm: owner_firm, typology:, price: 10_000_000, carpet_area_sqft: 700,
        building: create(:building, firm: owner_firm, city:, locality:, name:))
    end

    def matching_lead(owner_firm, assignee)
      create(:lead, firm: owner_firm, lead_status: new_status, assigned_user: assignee,
        name: "Secret Client", budget_max: 10_000_000, transaction_type: "sale",
        property_type: ready_type).tap do |lead|
        lead.typologies << typology
        lead.localities << locality
      end
    end

    it "hides the demo firm both ways and still searches the catalog" do
      demo_listing = listing_for(firm, name: "Demo Tower")
      other_listing = listing_for(other_firm, name: "Sea Face Tower")
      witness_listing = listing_for(witness, name: "Witness House")
      matching_lead(firm, user)
      shown = matching_lead(witness, witness_agent)
      demo_headers = sign_in(user)
      other_headers = sign_in(other_owner)

      get "/api/v1/properties/marketplace", headers: other_headers
      ids = response.parsed_body["properties"].map { |row| row["id"] }
      expect(ids).not_to include(demo_listing.id)
      expect(ids).to include(witness_listing.id)

      get "/api/v1/properties/marketplace", headers: demo_headers
      expect(response.parsed_body["properties"]).to eq([])

      get "/api/v1/properties/#{other_listing.id}/marketplace", headers: demo_headers
      expect(response).to have_http_status(:not_found)

      get "/api/v1/properties/#{demo_listing.id}/marketplace", headers: other_headers
      expect(response).to have_http_status(:not_found)

      post "/api/v1/properties/#{other_listing.id}/lead_matches", headers: other_headers, as: :json

      expect(response.parsed_body["marketplace_firms"].map { |row| row["id"] }).to eq([ witness.id ])
      expect(response.parsed_body["marketplace_matches"].map { |row| row["firm_id"] }).to eq([ witness.id ])
      expect(response.parsed_body["marketplace_matches"].map { |row| row["code"] }).to eq([ shown.code ])

      catalog = Current.set(firm: nil, firm_scope_bypassed: true) do
        create(:project, :catalog, firm: nil, name: "Harbour Catalog", external_ref: "PRHARBO1",
          city:, locality:, starting_budget: 12_000_000)
      end

      get "/api/v1/projects/search", params: { q: "Harbour", include_marketplace: true }, headers: demo_headers

      ids = response.parsed_body.fetch("projects").map { |row| row["id"] }
      expect(ids).to include(catalog.id)
    end
  end

  describe "Facebook" do
    it "still loads the integration for the review firm" do
      body = request_code
      post "/api/v1/auth/verify",
        params: { request_id: body["request_id"], code: Auth::ReviewLogin::CODE }, as: :json
      headers = { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }

      get "/api/v1/facebook/integration", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("configured")
      expect(response.body).not_to include("demo_account_restricted")
    end
  end

  it "cannot be set through the admin firm form" do
    expect(Admin::FirmForm::FIRM_FIELDS).not_to include(:review_demo, :field_demo)
  end
end
