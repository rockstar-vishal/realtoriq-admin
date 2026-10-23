# frozen_string_literal: true

require "rails_helper"

RSpec.describe "GET /projects category filter" do
  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:user) { create(:user, :super_admin, firm:) }
  let(:shop) { create(:typology, name: "Shop", code: "shop", category: "commercial") }
  let(:home) { create(:typology, name: "2 BHK", code: "2_bhk") }

  def auth
    post "/api/v1/auth/otp", params: { mobile: user.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify", params: { request_id:, code: deliverer.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
  end

  it "lists a project with two shop rows once" do
    shops = create(:project, firm:, name: "Two shops", starting_budget: 8_000_000)
    create(:project_typology, project: shops, typology: shop, label: "Front", starting_price: 8_000_000)
    create(:project_typology, project: shops, typology: shop, label: "Rear", starting_price: 7_000_000)
    homes = create(:project, firm:, name: "Homes only", starting_budget: 9_000_000)
    create(:project_typology, project: homes, typology: home, starting_price: 9_000_000)

    get "/api/v1/projects", params: { category: "commercial" }, headers: auth

    expect(response).to have_http_status(:ok)
    ids = response.parsed_body["projects"].map { |row| row["id"] }
    expect(ids.count(shops.id)).to eq(1)
    expect(ids).not_to include(homes.id)
    expect(subscription).to be_present
  end
end
