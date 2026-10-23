# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 brand website" do
  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:super_admin) { create(:user, :super_admin, firm:) }
  let!(:agent) { create(:user, firm:, role: :agent) }
  let!(:mobile) { create(:contact_channel, :mobile, :verified, firm:) }
  let(:city) { create(:city) }
  let(:locality) { create(:locality, city:) }
  let!(:project) { create(:project, firm:, city:, locality:, name: "Aurum Vista", lat: 19.07, lng: 73.02) }
  let!(:project_typology) { create(:project_typology, project:) }
  let!(:property) { create(:property, firm:) }

  def auth(user)
    post "/api/v1/auth/otp", params: { mobile: user.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify", params: { request_id:, code: deliverer.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
  end

  it "is super-admin only and does not rewrite the verified mobile channel" do
    get "/api/v1/firm/website", headers: auth(agent)
    expect(response).to have_http_status(:forbidden)

    get "/api/v1/firm/website", headers: auth(super_admin)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("website", "suggested_phone")).to eq(mobile.value)
    expect(response.parsed_body.dig("website", "phone")).to be_nil
    expect(response.parsed_body.dig("website", "enabled")).to be(true)

    patch "/api/v1/firm/website", params: {
      about: "Family brokerage.",
      website_phone: "98201 44210",
      address_line1: "12 MG Road",
      city_id: city.id,
      locality_id: locality.id,
      pincode: "411001",
      lat: 18.52,
      lng: 73.85,
      website_enabled: false
    }, headers: auth(super_admin), as: :json

    expect(response).to have_http_status(:ok)
    firm.reload
    expect(firm.about).to eq("Family brokerage.")
    expect(firm.website_phone).to eq("+919820144210")
    expect(firm.website_enabled).to be(false)
    expect(firm.address_line1).to eq("12 MG Road")
    expect(mobile.reload.value).not_to eq("+919820144210")
    expect(AuditEvent.where(action: "website.disabled").count).to eq(1)
    expect(AuditEvent.where(action: "website.phone_changed").count).to eq(1)
  end

  it "rejects an SVG logo" do
    blob = ActiveStorage::Blob.create_before_direct_upload!(
      filename: "logo.svg", byte_size: 32, checksum: Digest::MD5.base64digest("x" * 32),
      content_type: "image/svg+xml",
      metadata: { firm_id: firm.id, purpose: "firm_logo" }
    )
    blob.upload(StringIO.new("x" * 32))

    patch "/api/v1/firm/website", params: { logo_signed_id: blob.signed_id },
      headers: auth(super_admin), as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(firm.reload.logo).not_to be_attached
  end

  it "turns a listing off without changing its slug" do
    headers = auth(super_admin)
    slug = project.slug

    patch "/api/v1/projects/#{project.id}", params: { name: "Renamed Vista", on_website: false },
      headers:, as: :json

    expect(response).to have_http_status(:ok)
    project.reload
    expect(project.slug).to eq(slug)
    expect(project.on_website).to be(false)
    expect(response.parsed_body.dig("project", "website_url")).to be_nil

    patch "/api/v1/properties/#{property.id}", params: { on_website: false },
      headers: auth(agent), as: :json

    expect(response).to have_http_status(:ok)
    expect(property.reload.on_website).to be(false)
  end

  it "leaves a cleared website phone cleared" do
    firm.update!(website_phone: "+919820144210")
    headers = auth(super_admin)

    patch "/api/v1/firm/website", params: { website_phone: "" }, headers:, as: :json

    expect(response).to have_http_status(:ok)
    expect(firm.reload.website_phone).to be_nil
    expect(response.parsed_body.dig("website", "phone")).to be_nil
    expect(response.parsed_body.dig("website", "suggested_phone")).to eq(mobile.value)

    patch "/api/v1/firm/website", params: { about: "Still blank." }, headers:, as: :json

    expect(firm.reload.website_phone).to be_nil
  end

  it "refuses a pin when only one coordinate is sent" do
    firm.update!(lat: 18.5, lng: 73.8)

    patch "/api/v1/firm/website", params: { lat: 19.1 }, headers: auth(super_admin), as: :json

    expect(response).to have_http_status(:unprocessable_content)
    firm.reload
    expect(firm.lat).to eq(18.5)
    expect(firm.lng).to eq(73.8)
  end
end
