# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 authenticated endpoints" do
  let(:plan) { create(:plan, max_devices: 3, max_users: 5) }
  let(:firm) { create(:firm, :with_channels, status: :active) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:user) { create(:user, :super_admin, firm:) }

  def tokens_for(target = user)
    post "/api/v1/auth/otp", params: { mobile: target.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify", params: { request_id:, code: deliverer.last.code }, as: :json
    response.parsed_body
  end

  def auth_headers(target = user)
    { "Authorization" => "Bearer #{tokens_for(target)['access_token']}" }
  end

  describe "GET /me" do
    it "returns the user, firm, subscription and resolved permissions" do
      get "/api/v1/me", headers: auth_headers

      body = response.parsed_body
      expect(response).to have_http_status(:ok)
      expect(body.dig("user", "role")).to eq("super_admin")
      expect(body.dig("firm", "code")).to eq(firm.code)
      expect(body.dig("subscription", "entitled")).to be(true)
      expect(body.dig("permissions", "verify_contact_channels")).to be(true)
      expect(body.dig("limits", "devices")).to eq(3)
    end

    it "resolves permissions server-side for a non-super-admin" do
      agent = create(:user, firm:, role: :agent)

      get "/api/v1/me", headers: auth_headers(agent)

      expect(response.parsed_body.dig("permissions", "verify_contact_channels")).to be(false)
    end

    it "rejects a request with no token" do
      get "/api/v1/me"

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body.dig("error", "code")).to eq("unauthorized")
    end

    it "rejects a garbage token" do
      get "/api/v1/me", headers: { "Authorization" => "Bearer not.a.jwt" }

      expect(response).to have_http_status(:unauthorized)
    end

    it "stops working as soon as the session is revoked, without waiting for the JWT to expire" do
      headers = auth_headers
      user.auth_sessions.live.sole.revoke!

      get "/api/v1/me", headers: headers

      expect(response).to have_http_status(:unauthorized)
    end

    it "returns account_suspended once the firm is suspended" do
      headers = auth_headers
      firm.suspend!(reason: "Payment overdue")

      get "/api/v1/me", headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("account_suspended")
    end

    it "returns subscription_lapsed once the period runs out" do
      headers = auth_headers
      subscription.update!(current_period_start: 2.months.ago.to_date,
                           current_period_end: 1.day.ago.to_date)

      get "/api/v1/me", headers: headers

      expect(response).to have_http_status(:payment_required)
      expect(response.parsed_body.dig("error", "code")).to eq("subscription_lapsed")
    end

    it "refuses a disabled user" do
      headers = auth_headers
      user.update!(status: :disabled)

      get "/api/v1/me", headers: headers

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /reference" do
    before do
      create(:city, name: "Navi Mumbai", state: "Maharashtra")
      LeadStatus.find_or_create_by!(name: "Dead") { |s| s.is_dead = true }
      Typology.find_or_create_by!(name: "2.5 BHK") { |t| t.bedrooms = 2.5 }
    end

    it "returns the masters bundle the app's dropdowns need" do
      get "/api/v1/reference", headers: auth_headers

      body = response.parsed_body
      expect(response).to have_http_status(:ok)
      expect(body["cities"].first).to include("name" => "Navi Mumbai", "state_code" => "MH")
      expect(body["lead_statuses"].find { |s| s["name"] == "Dead" }["is_dead"]).to be(true)
      expect(body["typologies"].find { |t| t["name"] == "2.5 BHK" }["bedrooms"]).to eq(2.5)
      expect(body["transaction_types"].map { |t| t["code"] }).to eq(%w[sale rent])
    end

    it "revalidates cheaply with an ETag" do
      headers = auth_headers
      get "/api/v1/reference", headers: headers
      etag = response.headers["ETag"]

      get "/api/v1/reference", headers: headers.merge("If-None-Match" => etag)

      expect(response).to have_http_status(:not_modified)
    end
  end

  describe "firm contact channels" do
    let(:channel) { firm.contact_channels.find_by(kind: :email) }

    it "lets any user read them" do
      agent = create(:user, firm:, role: :agent)

      get "/api/v1/firm/contact_channels", headers: auth_headers(agent)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["channels"].size).to eq(3)
      expect(response.parsed_body["can_verify"]).to be(false)
    end

    it "lets the super admin request a code" do
      post "/api/v1/firm/contact_channels/#{channel.id}/request_code", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(deliverer.last.transport).to eq(:email)
    end

    it "refuses an agent trying to request a code" do
      agent = create(:user, firm:, role: :agent)

      post "/api/v1/firm/contact_channels/#{channel.id}/request_code", headers: auth_headers(agent)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("forbidden_role")
    end

    it "verifies with the right code and records who did it" do
      headers = auth_headers
      post "/api/v1/firm/contact_channels/#{channel.id}/request_code", headers: headers

      post "/api/v1/firm/contact_channels/#{channel.id}/verify",
        params: { code: deliverer.last.code }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(channel.reload).to be_verified
      expect(channel.verified_by_user).to eq(user)
    end

    it "rejects a wrong code and counts down" do
      headers = auth_headers
      post "/api/v1/firm/contact_channels/#{channel.id}/request_code", headers: headers

      post "/api/v1/firm/contact_channels/#{channel.id}/verify",
        params: { code: "000000" }, headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "details", "attempts_left")).to eq(4)
      expect(channel.reload).not_to be_verified
    end

    it "will not touch another firm's channel" do
      other_channel = create(:firm, :with_channels).contact_channels.first

      post "/api/v1/firm/contact_channels/#{other_channel.id}/request_code", headers: auth_headers

      expect(response).to have_http_status(:not_found)
      expect(other_channel.reload).to be_verification_unverified
    end
  end
end
