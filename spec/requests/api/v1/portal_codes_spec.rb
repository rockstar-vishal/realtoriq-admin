# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 portal codes" do
  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:owner) { create(:user, :super_admin, firm:) }
  let!(:agent) { create(:user, firm:, role: :agent) }
  let(:city) { create(:city) }
  let(:locality) { create(:locality, city:) }

  def auth(user)
    post "/api/v1/auth/otp", params: { mobile: user.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify", params: { request_id:, code: deliverer.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
  end

  it "lets the owner save a project code and refuses a second project with the same one" do
    first = create(:project, firm:, city:, locality:)
    second = create(:project, firm:, city:, locality:)
    headers = auth(owner)

    patch "/api/v1/projects/#{first.id}/portal_codes",
      params: { "99acres" => "  ACME  1 " }, headers:, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("project", "portal_codes", "99acres")).to eq("ACME 1")
    expect(first.reload.portal_99acres_code).to eq("ACME 1")

    patch "/api/v1/projects/#{second.id}/portal_codes",
      params: { "99acres" => "acme 1" }, headers:, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "message")).to include("already saved")
    expect(second.reload.portal_99acres_code).to be_nil

    patch "/api/v1/projects/#{first.id}/portal_codes",
      params: { "99acres" => "" }, headers:, as: :json
    expect(first.reload.portal_99acres_code).to be_nil
  end

  it "hides project portal codes from an agent and from a catalog project" do
    project = create(:project, firm:, city:, locality:)
    catalog = create(:project, :catalog, firm: nil, city:, external_ref: "launchiq-codes")
    headers = auth(agent)

    patch "/api/v1/projects/#{project.id}/portal_codes",
      params: { "housing" => "H-1" }, headers:, as: :json
    expect(response).to have_http_status(:forbidden)

    patch "/api/v1/projects/#{catalog.id}/portal_codes",
      params: { "housing" => "H-1" }, headers: auth(owner), as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("catalog_readonly")
  end

  it "lets any firm user save a property code once" do
    first = create(:property, firm:)
    second = create(:property, firm:)
    headers = auth(agent)

    patch "/api/v1/properties/#{first.id}/portal_codes",
      params: { "magicbricks" => "MB-9" }, headers:, as: :json
    expect(response).to have_http_status(:ok)
    expect(first.reload.portal_magicbricks_code).to eq("MB-9")

    patch "/api/v1/properties/#{second.id}/portal_codes",
      params: { "magicbricks" => "mb-9" }, headers:, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(second.reload.portal_magicbricks_code).to be_nil
  end
end
