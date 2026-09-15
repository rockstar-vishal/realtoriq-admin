# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 lead mappings" do
  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:manager) { create(:user, :manager, firm:) }
  let!(:agent) { create(:user, firm:, role: :agent) }
  let!(:new_status) { create(:lead_status, :new_lead) }
  let!(:lead) { create(:lead, firm:, lead_status: new_status, assigned_user: manager) }
  let(:project) { create(:project, firm:) }
  let(:property) { create(:property, firm:) }

  def auth(user)
    post "/api/v1/auth/otp", params: { mobile: user.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify", params: { request_id:, code: deliverer.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
  end

  describe "POST /leads/:id/projects" do
    it "maps a project onto the lead" do
      post "/api/v1/leads/#{lead.id}/projects", params: { project_id: project.id },
        headers: auth(manager), as: :json

      expect(response).to have_http_status(:created)
      mapped = response.parsed_body.dig("lead", "mapped_projects")
      expect(mapped.size).to eq(1)
      expect(mapped.first.dig("project", "id")).to eq(project.id)
      expect(mapped.first["id"]).to be_present
    end

    it "maps a catalog project without copying it" do
      catalog = create(:project, :catalog, firm:)

      post "/api/v1/leads/#{lead.id}/projects", params: { project_id: catalog.id },
        headers: auth(manager), as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("lead", "mapped_projects", 0, "project", "source"))
        .to eq("catalog")
      expect(Project.across_firms.from_own.where(firm:, name: catalog.name)).not_to exist
    end

    it "refuses another firm's project" do
      stranger = create(:project, firm: create(:firm))

      post "/api/v1/leads/#{lead.id}/projects", params: { project_id: stranger.id },
        headers: auth(manager), as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "is 404 for a lead the agent cannot see" do
      post "/api/v1/leads/#{lead.id}/projects", params: { project_id: project.id },
        headers: auth(agent), as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /leads/:lead_id/projects/:id" do
    it "removes the mapping and keeps the project" do
      mapping = create(:lead_project, firm:, lead:, project:)

      delete "/api/v1/leads/#{lead.id}/projects/#{mapping.id}", headers: auth(manager)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("lead", "mapped_projects")).to eq([])
      expect(Project.across_firms.find(project.id)).to be_present
    end
  end

  describe "POST /leads/:id/properties" do
    it "maps a listing onto the lead" do
      post "/api/v1/leads/#{lead.id}/properties", params: { property_id: property.id },
        headers: auth(manager), as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("lead", "mapped_properties").size).to eq(1)
    end
  end

  describe "POST /leads/:id/matches" do
    it "returns an empty list until LaunchIQ is wired" do
      post "/api/v1/leads/#{lead.id}/matches", headers: auth(manager), as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("matches" => [])
    end

    it "is 404 for a lead the agent cannot see" do
      post "/api/v1/leads/#{lead.id}/matches", headers: auth(agent), as: :json

      expect(response).to have_http_status(:not_found)
    end
  end
end
