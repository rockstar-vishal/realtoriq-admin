# frozen_string_literal: true

require "rails_helper"
require "vips"

RSpec.describe "Turbo share link lookup" do
  let(:token) { "share-link-test-token" }
  let(:firm) { create(:firm, status: :active, name: "Sethi Realty", rera_number: "A51900000001") }
  let!(:user) { create(:user, :agent, firm:) }
  let(:city) { create(:city, name: "Mumbai", state: "Maharashtra") }
  let(:catalog) do
    Current.set(firm_scope_bypassed: true) do
      create(:project, :catalog, firm: nil, name: "Harbour One", city:, external_ref: "PR4F2A9C")
    end
  end
  let!(:link) do
    project = catalog
    Current.firm = firm
    ProjectShareLink.create!(firm:, user:, project:)
  end

  before do
    allow(Realtoriq::Credentials).to receive(:inbound_token).and_return(token)
    create(:contact_channel, :mobile, firm:, value: "+919820155001")
    create(:contact_channel, :whatsapp, :verified, firm:, value: "+919811122233")
  end

  def png_bytes
    Vips::Image.black(20, 20).new_from_image([ 1, 2, 3 ]).copy(interpretation: :srgb).write_to_buffer(".png")
  end

  it "rejects a missing or wrong token" do
    get "/turbo/share_links/#{link.token}"
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to eq("error" => "Unauthorized")

    get "/turbo/share_links/#{link.token}", headers: { "Authorization" => "Bearer wrong-token" }
    expect(response).to have_http_status(:unauthorized)
  end

  it "hides an unknown token and a firm that is not active" do
    get "/turbo/share_links/missing-token", headers: { "Authorization" => "Bearer #{token}" }
    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body).to eq("error" => "Not found")

    firm.update!(status: :suspended, suspended_at: Time.current, suspension_reason: "Paused")
    get "/turbo/share_links/#{link.token}", headers: { "Authorization" => "Bearer #{token}" }
    expect(response).to have_http_status(:not_found)
  end

  it "returns the calling firm's card and the catalog code" do
    firm.logo.attach(io: StringIO.new(png_bytes), filename: "logo.png", content_type: "image/png")
    get "/turbo/share_links/#{link.token}", headers: { "Authorization" => "Bearer #{token}" }

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body["project_code"]).to eq("PR4F2A9C")
    expect(body["firm"]).to include(
      "name" => "Sethi Realty",
      "mobile" => nil,
      "whatsapp" => "+919811122233",
      "rera_number" => "A51900000001"
    )
    expect(body["firm"]["logo_url"]).to be_present
  end

  it "allows 600 lookups a minute from one address" do
    store = ActiveSupport::Cache::MemoryStore.new
    allow(Rails).to receive(:cache).and_return(store)
    headers = { "Authorization" => "Bearer #{token}" }
    get "/turbo/share_links/#{link.token}", headers: headers
    expect(response).to have_http_status(:ok)

    key = store.instance_variable_get(:@data).keys.find { |name| name.include?("share-link") }
    store.write(key, 599)
    get "/turbo/share_links/#{link.token}", headers: headers
    expect(response).to have_http_status(:ok)
    get "/turbo/share_links/#{link.token}", headers: headers
    expect(response).to have_http_status(:too_many_requests)
    expect(response.parsed_body).to eq("error" => "Too many requests")
  end
end
