# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 inbound credentials" do
  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:owner) { create(:user, :super_admin, firm:) }
  let!(:agent) { create(:user, firm:, role: :agent) }

  def auth(user)
    post "/api/v1/auth/otp", params: { mobile: user.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify", params: { request_id:, code: deliverer.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
  end

  it "gives the owner one key and four copy-ready messages" do
    get "/api/v1/inbound_credentials", headers: auth(owner)

    expect(response).to have_http_status(:ok)
    body = response.parsed_body["inbound_credential"]
    expect(body["token"]).to be_present
    expect(body["portals"].map { |portal| portal["channel"] }).to eq(%w[99acres magicbricks housing general])
    message = body["portals"].first["message"]
    expect(message).to include(body["token"])
    expect(message).to include(body["portals"].first["projects_url"])
    expect(body["portals"].first["projects_url"]).not_to include(body["token"])
    expect(body["portals"].last["message"]).to include("transaction_type")
    expect(body["portals"].first["message"]).not_to include("transaction_type")
    expect(body["portals"].first["message"]).to include("Portal codes")
    expect(body["portals"].last["message"]).not_to include("Portal codes")
    expect(body["portals"].last["message"]).to include("the H- code")
  end

  it "rotates the key and records it without storing the token" do
    get "/api/v1/inbound_credentials", headers: auth(owner)
    old = response.parsed_body.dig("inbound_credential", "token")

    post "/api/v1/inbound_credentials/rotate", headers: auth(owner)
    expect(response).to have_http_status(:ok)
    fresh = response.parsed_body.dig("inbound_credential", "token")
    expect(fresh).to be_present
    expect(fresh).not_to eq(old)

    event = AuditEvent.order(:created_at).last
    expect(event.action).to eq("inbound_credential.rotate")
    expect(event.metadata.to_s).not_to include(fresh)
  end

  it "hides the key from an agent" do
    get "/api/v1/inbound_credentials", headers: auth(agent)

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.dig("error", "code")).to eq("forbidden_role")
  end
end
