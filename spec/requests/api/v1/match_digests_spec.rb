# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 match digest" do
  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:super_admin) { create(:user, :super_admin, firm:) }
  let!(:manager) { create(:user, :manager, firm:) }

  def auth(user)
    post "/api/v1/auth/otp", params: { mobile: user.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify", params: { request_id:, code: deliverer.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
  end

  it "is 404 for anyone except the super admin" do
    get "/api/v1/match_digest", headers: auth(manager)

    expect(response).to have_http_status(:not_found)
  end

  it "returns the firm's list to the super admin" do
    Current.set(firm:) do
      MatchDigest.create!(
        firm:, generated_at: Time.current, fingerprint: "abc",
        lead_items: [
          {
            "lead_id" => "lead-1", "code" => "L-0001", "name" => "Asha",
            "budget" => 10_000_000, "typologies" => [ "2 BHK" ], "localities" => [ "Kharghar" ],
            "match_count" => 2, "new_count" => 1, "top_score" => 100, "match_ids" => [ "property:p1" ]
          }
        ],
        listing_items: []
      )
    end

    get "/api/v1/match_digest", headers: auth(super_admin)

    expect(response).to have_http_status(:ok)
    body = response.parsed_body["match_digest"]
    expect(body["lead_items"].first["name"]).to eq("Asha")
    expect(body["lead_items"].first["new_count"]).to eq(1)
    expect(body["lead_items"].first).not_to have_key("match_ids")
    expect(body).not_to have_key("notification_pending")
  end

  it "returns null before the first scan" do
    get "/api/v1/match_digest", headers: auth(super_admin)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["match_digest"]).to be_nil
  end
end
