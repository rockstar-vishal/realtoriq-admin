# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Mapped customers" do
  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:broker) { create(:user, :agent, firm:) }
  let!(:manager) { create(:user, :manager, firm:) }
  let!(:status) { create(:lead_status, :new_lead) }
  let!(:project) { create(:project, firm:) }
  let!(:property) { create(:property, firm:) }
  let!(:lead) { create(:lead, firm:, lead_status: status, assigned_user: broker, name: "Meera Shah") }

  def auth(user)
    post "/api/v1/auth/otp", params: { mobile: user.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify", params: { request_id:, code: deliverer.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
  end

  it "lists a lead mapped to the project and hides one mapped only to someone else's book" do
    create(:lead_project, lead:, project:, firm:)
    other = create(:lead, firm:, lead_status: status, assigned_user: manager, name: "Other Client")
    create(:lead_project, lead: other, project:, firm:)

    get "/api/v1/projects/#{project.id}/mapped_customers", headers: auth(broker), as: :json

    expect(response).to have_http_status(:ok)
    ids = response.parsed_body["customers"].map { |row| row["id"] }
    expect(ids).to eq([ lead.id ])
    expect(response.parsed_body["customers"].first["name"]).to eq("Meera Shah")
  end

  it "omits a withdrawn project mapping" do
    create(:lead_project, lead:, project:, firm:, withdrawn_at: Time.current)

    get "/api/v1/projects/#{project.id}/mapped_customers", headers: auth(manager), as: :json

    expect(response.parsed_body["customers"]).to eq([])
  end

  it "lists a lead mapped to the property" do
    create(:lead_property, lead:, property:, firm:)

    get "/api/v1/properties/#{property.id}/mapped_customers", headers: auth(manager), as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["customers"].map { |row| row["id"] }).to eq([ lead.id ])
  end
end
