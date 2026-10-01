# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 lead import" do
  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:manager) { create(:user, :manager, firm:) }
  let!(:status) { create(:lead_status, :new_lead) }
  let!(:property_type) { create(:property_type, name: "Under construction") }
  let!(:typology) { create(:typology, name: "2 BHK") }
  let!(:city) { create(:city, name: "Mumbai", state: "Maharashtra") }
  let!(:locality) { create(:locality, city:, name: "Kharghar") }

  def auth(user)
    post "/api/v1/auth/otp", params: { mobile: user.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify", params: { request_id:, code: deliverer.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
  end

  def upload(content, name: "leads.csv", type: "text/csv")
    file = Tempfile.new([ "leads", File.extname(name) ])
    file.write(content)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, type, original_filename: name)
  end

  it "returns the sample and imports a filled sheet" do
    headers = auth(manager)
    get "/api/v1/leads/import_template", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Example lead")
    expect(response.body).to include("Project codes")

    csv = CSV.generate do |sheet|
      sheet << Leads::Import::HEADERS.map(&:last)
      sheet << [
        "Rhea Kapoor", "9820155099", nil, nil, "sale", "Under construction",
        "1,20,00,000", "2bhk", "Kharghar", nil, nil, nil, nil, nil, nil
      ]
    end

    expect {
      post "/api/v1/leads/import", params: { file: upload(csv) }, headers: headers
    }.to change { Lead.across_firms.count }.by(1)

    body = response.parsed_body
    expect(response).to have_http_status(:ok)
    expect(body["created_count"]).to eq(1)
    expect(body["failed_count"]).to eq(0)
    expect(body.dig("results", 0, "lead_code")).to eq("L-0001")
  end

  it "refuses an Excel workbook by its file name" do
    post "/api/v1/leads/import",
      params: { file: upload("not a workbook", name: "leads.xlsx") },
      headers: auth(manager)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "message")).to include("CSV UTF-8")
    expect(Lead.across_firms.count).to eq(0)
  end
end
