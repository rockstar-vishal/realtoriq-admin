# frozen_string_literal: true

require "rails_helper"

RSpec.describe "GET /api/v1/reference categories" do
  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:user) { create(:user, :super_admin, firm:) }
  let!(:home) { create(:typology, name: "2 BHK", code: "2_bhk") }

  def auth
    post "/api/v1/auth/otp", params: { mobile: user.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify", params: { request_id:, code: Notifications::Deliverer.current.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
  end

  it "returns pickable configurations and the new lists, and the cache key is v4" do
    create(:typology, name: "Villa", code: "villa")
    create(:typology, name: "Hidden Shop", code: "hidden_shop", category: "commercial", active: false)
    merged = create(:typology, name: "Old Flat", code: "old_flat", active: false, merged_into: home)
    headers = auth

    get "/api/v1/reference", headers: headers

    body = response.parsed_body
    names = body["typologies"].map { |row| row["name"] }
    expect(names).to include("2 BHK", "Villa")
    expect(names).not_to include("Hidden Shop", merged.name)
    two = body["typologies"].find { |row| row["code"] == "2_bhk" }
    expect(two).to include("category" => "residential", "area_kind" => "carpet", "uses_floor_band" => true)
    villa = body["typologies"].find { |row| row["code"] == "villa" }
    expect(villa["uses_floor_band"]).to be(false)
    expect(body["categories"].map { |row| row["code"] }).to eq(%w[residential commercial land])
    expect(body["area_units"].map { |row| row["code"] }).to include("guntha")
    expect(body["pre_leased_details"].map { |row| row["key"] }).to include("lease_monthly_rent")
    tenant = body["pre_leased_details"].find { |row| row["key"] == "tenant_type" }
    expect(tenant["options"]).to include("code" => "fb", "label" => "F&B")
    expect(body["tenant_types"].find { |row| row["code"] == "fb" }).to include("name" => "F&B")
    expect(body["tenant_types"].find { |row| row["code"] == "bank" }).to include("name" => "Bank")
    expect(two["details"].map { |field| field["key"] }).to include("furnishing")
    furnishing = two["details"].find { |field| field["key"] == "furnishing" }
    expect(furnishing["options"]).to include("code" => "semi", "label" => "Semi-furnished")

    controller = Api::V1::ReferenceController.new
    allow(controller).to receive(:current_firm).and_return(firm)
    before_key = controller.send(:cache_key)
    expect(before_key).to start_with("api/v1/reference/v5/#{firm.id}")

    ConfigurationAlias.create!(key: "twobhk", typology: home, source: "seed")
    later = Api::V1::ReferenceController.new
    allow(later).to receive(:current_firm).and_return(firm)
    expect(later.send(:cache_key)).not_to eq(before_key)
  end

  it "lists a shop's detail fields and an empty list for a configuration with no spec" do
    create(:typology, name: "Shop", code: "shop", category: "commercial")
    create(:typology, name: "Studio loft", code: "studio_loft")
    headers = auth

    get "/api/v1/reference", headers: headers

    body = response.parsed_body
    shop = body["typologies"].find { |row| row["code"] == "shop" }
    expect(shop["details"].map { |field| field["key"] }).to include("frontage_ft")
    frontage = shop["details"].find { |field| field["key"] == "frontage_ft" }
    expect(frontage).to include(
      "label" => "Frontage", "type" => "integer", "min" => 1, "max" => 500, "unit" => "feet"
    )
    studio = body["typologies"].find { |row| row["code"] == "studio_loft" }
    expect(studio["details"]).to eq([])
  end
end
