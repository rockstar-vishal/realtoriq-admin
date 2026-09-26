# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 lead visits" do
  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:manager) { create(:user, :manager, firm:) }
  let!(:agent) { create(:user, firm:, role: :agent) }
  let!(:other_agent) { create(:user, firm:, role: :agent) }
  let!(:new_status) { create(:lead_status, :new_lead) }
  let!(:lead) { create(:lead, firm:, lead_status: new_status, assigned_user: agent) }
  let!(:project) { create(:project, firm:) }
  let!(:property) { create(:property, firm:) }

  def auth(user)
    post "/api/v1/auth/otp", params: { mobile: user.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify", params: { request_id:, code: deliverer.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
  end

  describe "POST /leads/:id/visits" do
    it "logs a siteless visit and marks the lead visited" do
      status_id = lead.lead_status_id
      next_action_at = lead.next_action_at

      post "/api/v1/leads/#{lead.id}/visits",
        params: { visited_on: "2026-09-20", notes: "Walked the site" },
        headers: auth(agent), as: :json

      expect(response).to have_http_status(:created)
      body = response.parsed_body["visit"]
      expect(body["visited_on"]).to eq("2026-09-20")
      expect(body["notes"]).to eq("Walked the site")
      expect(body["projects"]).to eq([])
      expect(body.dig("user", "id")).to eq(agent.id)

      lead.reload
      expect(lead.lead_status_id).to eq(status_id)
      expect(lead.next_action_at).to eq(next_action_at)

      get "/api/v1/leads/#{lead.id}", headers: auth(agent)
      detail = response.parsed_body["lead"]
      expect(detail).not_to have_key("first_visit_at")
      expect(detail["visited"]).to be(true)
      expect(detail["visit_count"]).to eq(1)
    end

    it "rejects a project that is not mapped to the lead" do
      post "/api/v1/leads/#{lead.id}/visits",
        params: { visited_on: "2026-09-20", project_ids: [ project.id ] },
        headers: auth(agent), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("not_mapped")
    end

    it "rejects a date after today in IST" do
      post "/api/v1/leads/#{lead.id}/visits",
        params: { visited_on: "2099-01-01" },
        headers: auth(agent), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("future_visited_at")
    end

    it "requires visited_on" do
      post "/api/v1/leads/#{lead.id}/visits",
        params: { notes: "no date" },
        headers: auth(agent), as: :json

      expect(response.parsed_body.dig("error", "code")).to eq("visited_on_required")
    end
  end

  describe "PATCH /leads/:id/visits/:id" do
    def log_visit_with_project
      create(:lead_project, lead:, project:)
      post "/api/v1/leads/#{lead.id}/visits",
        params: { visited_on: "2026-09-20", project_ids: [ project.id ] },
        headers: auth(agent), as: :json
      response.parsed_body.dig("visit", "id")
    end

    it "does not change the original logger" do
      visit_id = log_visit_with_project

      patch "/api/v1/leads/#{lead.id}/visits/#{visit_id}",
        params: { notes: "Updated", user_id: manager.id },
        headers: auth(manager), as: :json

      expect(response).to have_http_status(:ok)
      body = response.parsed_body["visit"]
      expect(body.dig("user", "id")).to eq(agent.id)
      expect(body["notes"]).to eq("Updated")
      expect(body["projects"].map { |row| row["id"] }).to eq([ project.id ])
      expect(body["visited_on"]).to eq("2026-09-20")
    end

    it "leaves sites when project_ids is omitted and clears them when sent empty" do
      visit_id = log_visit_with_project

      patch "/api/v1/leads/#{lead.id}/visits/#{visit_id}",
        params: { notes: "Still there" },
        headers: auth(agent), as: :json
      expect(response.parsed_body["visit"]["projects"].map { |row| row["id"] }).to eq([ project.id ])

      patch "/api/v1/leads/#{lead.id}/visits/#{visit_id}",
        params: { project_ids: [], property_ids: [] },
        headers: auth(agent), as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["visit"]["projects"]).to eq([])
    end

    it "keeps a site on the visit after the lead unmaps it" do
      visit_id = log_visit_with_project
      LeadProject.across_firms.where(lead_id: lead.id).delete_all

      patch "/api/v1/leads/#{lead.id}/visits/#{visit_id}",
        params: { notes: "Still the same outing", project_ids: [ project.id ] },
        headers: auth(agent), as: :json

      expect(response).to have_http_status(:ok)
      body = response.parsed_body["visit"]
      expect(body["notes"]).to eq("Still the same outing")
      expect(body["projects"].map { |row| row["id"] }).to eq([ project.id ])

      get "/api/v1/projects/#{project.id}/visitors", headers: auth(agent)
      expect(response.parsed_body["visitors"].map { |row| row.dig("lead", "id") }).to eq([ lead.id ])
    end

    it "drops a site from the visit after the lead unmapped it" do
      visit_id = log_visit_with_project
      LeadProject.across_firms.where(lead_id: lead.id).delete_all

      patch "/api/v1/leads/#{lead.id}/visits/#{visit_id}",
        params: { project_ids: [], property_ids: [] },
        headers: auth(agent), as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["visit"]["projects"]).to eq([])

      get "/api/v1/projects/#{project.id}/visitors", headers: auth(agent)
      expect(response.parsed_body["visitors"]).to eq([])
    end

    it "adds a currently mapped site on edit" do
      visit_id = log_visit_with_project
      extra = create(:project, firm:)
      create(:lead_project, lead:, project: extra)

      patch "/api/v1/leads/#{lead.id}/visits/#{visit_id}",
        params: { project_ids: [ project.id, extra.id ] },
        headers: auth(agent), as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["visit"]["projects"].map { |row| row["id"] })
        .to contain_exactly(project.id, extra.id)
    end

    it "rejects adding a site that is neither on the visit nor mapped" do
      visit_id = log_visit_with_project
      stranger = create(:project, firm:)

      patch "/api/v1/leads/#{lead.id}/visits/#{visit_id}",
        params: { project_ids: [ project.id, stranger.id ] },
        headers: auth(agent), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("not_mapped")
      expect(response.parsed_body.dig("visit")).to be_nil

      get "/api/v1/leads/#{lead.id}/visits", headers: auth(agent)
      row = response.parsed_body["visits"].find { |item| item["id"] == visit_id }
      expect(row["projects"].map { |site| site["id"] }).to eq([ project.id ])
    end
  end

  describe "visitor lists" do
    it "hides another agent's client from the project and property counts" do
      create(:lead_project, lead:, project:)
      create(:lead_property, lead:, property:)
      headers = auth(agent)
      post "/api/v1/leads/#{lead.id}/visits",
        params: { visited_on: "2026-09-20", project_ids: [ project.id ], property_ids: [ property.id ] },
        headers:, as: :json

      hidden = create(:lead, firm:, lead_status: new_status, assigned_user: other_agent)
      create(:lead_project, lead: hidden, project:)
      hidden_visit = create(:lead_visit, firm:, lead: hidden, user: other_agent)
      LeadVisitProject.create!(firm:, lead_visit: hidden_visit, project:)

      get "/api/v1/projects/#{project.id}/visitors", headers: auth(agent)
      expect(response.parsed_body["visit_count"]).to eq(1)
      expect(response.parsed_body["visitors"].map { |row| row.dig("lead", "id") }).to eq([ lead.id ])

      get "/api/v1/projects/#{project.id}/visitors", headers: auth(manager)
      expect(response.parsed_body["visit_count"]).to eq(2)

      get "/api/v1/properties/#{property.id}/visitors", headers: auth(agent)
      expect(response.parsed_body["visit_count"]).to eq(1)
      expect(response.parsed_body["visitors"].first.dig("lead", "display_name")).to eq(lead.display_name)
      expect(response.parsed_body["visitors"].first["last_visited_on"]).to eq("2026-09-20")
    end
  end

  describe "GET /leads/:id" do
    it "marks only the mapped sites that were on a visit" do
      create(:lead_project, lead:, project:)
      other_project = create(:project, firm:)
      create(:lead_project, lead:, project: other_project)
      post "/api/v1/leads/#{lead.id}/visits",
        params: { visited_on: "2026-09-20", project_ids: [ project.id ] },
        headers: auth(agent), as: :json

      get "/api/v1/leads/#{lead.id}", headers: auth(agent)
      rows = response.parsed_body.dig("lead", "mapped_projects")
      visited = rows.find { |row| row.dig("project", "id") == project.id }
      skipped = rows.find { |row| row.dig("project", "id") == other_project.id }
      expect(visited["visited"]).to be(true)
      expect(visited["visit_count"]).to eq(1)
      expect(visited["last_visited_on"]).to eq("2026-09-20")
      expect(skipped["visited"]).to be(false)
      expect(skipped["visit_count"]).to eq(0)
      expect(skipped["last_visited_on"]).to be_nil
    end
  end
end
