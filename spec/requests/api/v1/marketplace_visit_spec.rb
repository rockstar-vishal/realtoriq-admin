# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Marketplace visit passes and matches" do
  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active, name: "Shah Realty", rera_number: "A51800000000") }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:broker) { create(:user, :agent, firm:, name: "Ravi Shah", rera_number: "A51800000001") }
  let!(:manager) { create(:user, :manager, firm:) }
  let!(:new_status) { create(:lead_status, :new_lead) }
  let!(:dead_status) { create(:lead_status, :dead) }
  let!(:typology) { create(:typology, name: "2BHK") }
  let!(:other_typology) { create(:typology, name: "3BHK") }
  let(:city) { create(:city, name: "Mumbai", state: "Maharashtra") }
  let(:locality) { create(:locality, city:, name: "Worli") }
  let(:other_locality) { create(:locality, city:, name: "Bandra") }

  def auth(user)
    post "/api/v1/auth/otp", params: { mobile: user.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify", params: { request_id:, code: deliverer.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
  end

  def catalog_project(locality: nil)
    create(:project, :catalog, firm: nil, external_ref: "PR4F2A9C", name: "Harbour One",
      city:, locality:, starting_budget: 15_000_000, possession_label: "As per developer", possession_on: nil)
  end

  describe "POST /projects/:id/lead_matches" do
    let!(:catalog) do
      project = catalog_project(locality:)
      create(:project_typology, project:, typology:, starting_price: 15_000_000)
      project
    end
    let!(:lead) do
      create(:lead, firm:, lead_status: new_status, assigned_user: broker,
        budget_max: 16_000_000, transaction_type: "sale").tap do |row|
        row.typologies << typology
        row.localities << locality
      end
    end

    it "returns a live sale lead that shares a locality, configuration and budget" do
      post "/api/v1/projects/#{catalog.id}/lead_matches", headers: auth(broker), as: :json

      expect(response).to have_http_status(:ok)
      match = response.parsed_body["matches"].find { |row| row["id"] == lead.id }
      expect(match["kind"]).to eq("lead")
      expect(match["score"]).to eq(100)
      expect(match["matched_on"]).to eq(%w[locality price configuration])
    end

    it "hides a lead assigned to someone else from an agent" do
      lead.update!(assigned_user: manager)

      post "/api/v1/projects/#{catalog.id}/lead_matches", headers: auth(broker), as: :json

      expect(response.parsed_body["matches"].map { |row| row["id"] }).not_to include(lead.id)
    end

    it "skips a dead lead and a lead tagged to a different locality" do
      lead.update!(lead_status: dead_status, dead_reason: "Not buying")
      living = create(:lead, firm:, lead_status: new_status, assigned_user: broker,
        budget_max: 16_000_000, mobile: "+919811110000")
      living.typologies << typology
      living.localities << other_locality

      post "/api/v1/projects/#{catalog.id}/lead_matches", headers: auth(manager), as: :json

      ids = response.parsed_body["matches"].map { |row| row["id"] }
      expect(ids).not_to include(lead.id, living.id)
    end
  end

  describe "POST /leads/:id/matches" do
    it "returns the marketplace project that fits the lead" do
      project = catalog_project(locality:)
      create(:project_typology, project:, typology:, starting_price: 15_000_000)
      lead = create(:lead, firm:, lead_status: new_status, assigned_user: broker, budget_max: 16_000_000)
      lead.typologies << typology
      lead.localities << locality

      post "/api/v1/leads/#{lead.id}/matches", headers: auth(broker), as: :json

      expect(response).to have_http_status(:ok)
      match = response.parsed_body["matches"].find { |row| row["id"] == project.id }
      expect(match["source"]).to eq("catalog")
      expect(match["score"]).to eq(100)
      expect(match["matched_on"]).to eq(%w[locality price configuration])
    end
  end

  describe "mapping a global marketplace project" do
    it "maps the marketplace project without copying it" do
      catalog = catalog_project
      lead = create(:lead, firm:, lead_status: new_status, assigned_user: manager)

      post "/api/v1/leads/#{lead.id}/projects", params: { project_id: catalog.id },
        headers: auth(manager), as: :json

      expect(response).to have_http_status(:created)
      mapped = response.parsed_body.dig("lead", "mapped_projects", 0, "project")
      expect(mapped["id"]).to eq(catalog.id)
      expect(mapped["source"]).to eq("catalog")
      expect(mapped["external_ref"]).to eq("PR4F2A9C")
      expect(Project.unscoped.where(firm_id: firm.id, source: "own", external_ref: "PR4F2A9C")).to be_empty
    end
  end

  describe "visit passes" do
    let!(:catalog) { catalog_project }
    let!(:lead) do
      create(:lead, firm:, lead_status: new_status, assigned_user: broker,
        name: "Meera Shah", mobile: "+919876543210")
    end
    let!(:headers) { auth(broker) }
    let(:copy_id) do
      post "/api/v1/leads/#{lead.id}/projects", params: { project_id: catalog.id }, headers:, as: :json
      response.parsed_body.dig("lead", "mapped_projects", 0, "project", "id")
    end

    it "stores the turbo pass code and reuses an unused pass" do
      expect(Realtoriq::TurboClient).to receive(:create_visit_pass).once do |body|
        expect(body[:idempotency_key]).to be_present
        expect(body.dig(:broker, :firm_code)).to eq(firm.code)
        {
          "pass_code" => "CPVPABC123",
          "pass_url" => "https://launch.example/vp/token",
          "address" => "12 Sea Face",
          "rm_name" => "Asha Rao",
          "rm_contact" => "9876543210"
        }
      end

      post "/api/v1/leads/#{lead.id}/visit_passes",
        params: { project_id: copy_id, tentative_visit_planned: "2026-10-02T05:30:00Z" },
        headers:, as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("visit_pass", "pass_code")).to eq("CPVPABC123")
      expect(response.parsed_body.dig("visit_pass", "phone_suffix")).to eq("43210")

      post "/api/v1/leads/#{lead.id}/visit_passes",
        params: { project_id: copy_id, tentative_visit_planned: "2026-10-03T05:30:00Z" },
        headers:, as: :json

      expect(response).to have_http_status(:ok)
      expect(LeadVisitPass.across_firms.where(lead:).count).to eq(1)
    end

    it "refuses a pass when nobody has a RERA number" do
      broker.update!(rera_number: nil)
      firm.update!(rera_number: nil)

      expect(Realtoriq::TurboClient).not_to receive(:create_visit_pass)
      post "/api/v1/leads/#{lead.id}/visit_passes",
        params: { project_id: copy_id, tentative_visit_planned: "2026-10-02T05:30:00Z" },
        headers:, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("rera_required")
    end

    it "refreshes at most every six hours and records a follow-up without moving the pipeline" do
      allow(Realtoriq::TurboClient).to receive(:create_visit_pass).and_return("pass_code" => "CPVPABC123")
      post "/api/v1/leads/#{lead.id}/visit_passes",
        params: { project_id: copy_id, tentative_visit_planned: "2026-10-02T05:30:00Z" },
        headers:, as: :json
      pass_id = response.parsed_body.dig("visit_pass", "id")
      status_id = lead.reload.lead_status_id

      allow(Realtoriq::TurboClient).to receive(:fetch_visit_pass).and_return(
        "pass_code" => "CPVPABC123",
        "status" => "used",
        "lead_code" => "LD99",
        "status_name" => "Following",
        "status_detail" => { "dead_reason" => nil },
        "last_followup_at" => "2026-09-28T10:00:00Z",
        "last_followup_comment" => "Will visit Saturday",
        "next_followup_at" => "2026-09-30T04:30:00Z"
      )

      post "/api/v1/leads/#{lead.id}/visit_passes/#{pass_id}/refresh", headers:, as: :json

      expect(response).to have_http_status(:ok)
      body = response.parsed_body["visit_pass"]
      expect(body["turbo_lead_code"]).to eq("LD99")
      expect(body["turbo_status_name"]).to eq("Following")
      expect(body["last_fetched_at"]).to be_present
      expect(lead.reload.lead_status_id).to eq(status_id)
      expect(lead.next_action_at).to be_nil
      Current.firm = firm
      expect(lead.lead_followups.last.comment).to include("LD99", "Following", "Will visit Saturday")

      expect(Realtoriq::TurboClient).not_to receive(:fetch_visit_pass)
      post "/api/v1/leads/#{lead.id}/visit_passes/#{pass_id}/refresh", headers:, as: :json
      expect(response).to have_http_status(:too_many_requests)
      expect(response.parsed_body.dig("error", "code")).to eq("refresh_too_soon")
    end

    it "reuses the pending pass after a timeout and refuses a second pass once it is used" do
      allow(Realtoriq::TurboClient).to receive(:create_visit_pass)
        .and_raise(Realtoriq::TurboClient::Error.new("Could not reach LaunchIQ (Net::OpenTimeout)"))

      post "/api/v1/leads/#{lead.id}/visit_passes",
        params: { project_id: copy_id, tentative_visit_planned: "2026-10-02T05:30:00Z" },
        headers:, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      pending = LeadVisitPass.across_firms.find_by!(lead:)
      expect(pending.turbo_status).to eq("pending")

      allow(Realtoriq::TurboClient).to receive(:create_visit_pass) do |body|
        expect(body[:idempotency_key]).to eq(pending.id)
        { "pass_code" => "CPVPABC123", "pass_url" => "https://launch.example/vp/token" }
      end
      post "/api/v1/leads/#{lead.id}/visit_passes",
        params: { project_id: copy_id, tentative_visit_planned: "2026-10-02T05:30:00Z" },
        headers:, as: :json

      expect(response).to have_http_status(:created)
      expect(LeadVisitPass.across_firms.where(lead:).count).to eq(1)
      expect(response.parsed_body.dig("visit_pass", "pass_url")).to eq("https://launch.example/vp/token")

      pending.reload.update!(turbo_status: "used")
      expect(Realtoriq::TurboClient).not_to receive(:create_visit_pass)
      post "/api/v1/leads/#{lead.id}/visit_passes",
        params: { project_id: copy_id, tentative_visit_planned: "2026-10-03T05:30:00Z" },
        headers:, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("already_tagged")
    end

    it "stores a duplicate status and writes the contact-your-RM follow-up" do
      allow(Realtoriq::TurboClient).to receive(:create_visit_pass).and_return("pass_code" => "CPVPABC123")
      post "/api/v1/leads/#{lead.id}/visit_passes",
        params: { project_id: copy_id, tentative_visit_planned: "2026-10-02T05:30:00Z" },
        headers:, as: :json
      pass_id = response.parsed_body.dig("visit_pass", "id")
      message = "This client is already registered with the developer. Contact your RM to get yourself tagged, subject to the builder's policy."
      allow(Realtoriq::TurboClient).to receive(:fetch_visit_pass).with("CPVPABC123", firm.id).and_return(
        "pass_code" => "CPVPABC123",
        "status" => "duplicate",
        "message" => message
      )

      post "/api/v1/leads/#{lead.id}/visit_passes/#{pass_id}/refresh", headers:, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("visit_pass", "turbo_status")).to eq("duplicate")
      expect(response.parsed_body.dig("visit_pass", "status_message")).to eq(message)
      Current.firm = firm
      expect(lead.lead_followups.last.comment).to eq(message)
    end

    it "refuses a pass on a withdrawn mapping" do
      mapped_id = copy_id
      Current.firm = firm
      LeadProject.find_by!(lead:, project_id: mapped_id).update!(withdrawn_at: Time.current)

      expect(Realtoriq::TurboClient).not_to receive(:create_visit_pass)
      post "/api/v1/leads/#{lead.id}/visit_passes",
        params: { project_id: copy_id, tentative_visit_planned: "2026-10-02T05:30:00Z" },
        headers:, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("project_withdrawn")
    end
  end

  describe "GET /projects/:id/marketplace_leads" do
    let!(:catalog) { catalog_project }
    let!(:lead) do
      create(:lead, firm:, lead_status: new_status, assigned_user: broker, name: "Meera Shah")
    end
    let(:headers) { auth(broker) }
    let(:copy_id) do
      post "/api/v1/leads/#{lead.id}/projects", params: { project_id: catalog.id }, headers:, as: :json
      response.parsed_body.dig("lead", "mapped_projects", 0, "project", "id")
    end

    it "shows whether a pass was generated and whether the builder has the lead" do
      get "/api/v1/projects/#{copy_id}/marketplace_leads", headers:, as: :json

      expect(response).to have_http_status(:ok)
      row = response.parsed_body["leads"].find { |item| item["id"] == lead.id }
      expect(row["status"]).to eq("No pass")
      expect(row["pass_generated"]).to eq(false)
      expect(row["shared_with_builder"]).to eq(false)

      allow(Realtoriq::TurboClient).to receive(:create_visit_pass).and_return("pass_code" => "CPVPABC123")
      post "/api/v1/leads/#{lead.id}/visit_passes",
        params: { project_id: copy_id, tentative_visit_planned: "2026-10-02T05:30:00Z" },
        headers:, as: :json

      get "/api/v1/projects/#{catalog.id}/marketplace_leads", headers:, as: :json

      row = response.parsed_body["leads"].find { |item| item["id"] == lead.id }
      expect(row["status"]).to eq("Pass generated")
      expect(row["pass_code"]).to eq("CPVPABC123")
      expect(row["shared_with_builder"]).to eq(false)

      Current.firm = firm
      LeadVisitPass.find_by!(lead:, project_id: copy_id).update!(turbo_status: "used")
      get "/api/v1/projects/#{copy_id}/marketplace_leads", headers:, as: :json

      row = response.parsed_body["leads"].find { |item| item["id"] == lead.id }
      expect(row["status"]).to eq("Shared with builder")
      expect(row["shared_with_builder"]).to eq(true)
    end

    it "hides a lead assigned to someone else from an agent" do
      copy_id
      other = create(:lead, firm:, lead_status: new_status, assigned_user: manager,
        name: "Other Client", mobile: "+919811110099")
      Current.firm = firm
      create(:lead_project, firm:, lead: other, project_id: copy_id)

      get "/api/v1/projects/#{copy_id}/marketplace_leads", headers:, as: :json

      expect(response.parsed_body["leads"].map { |item| item["id"] }).to eq([ lead.id ])
    end

    it "returns the newest 25 mappings and the next page after that" do
      copy_id
      25.times do |n|
        other = create(:lead, firm:, lead_status: new_status, assigned_user: broker,
          name: "Client #{n}", mobile: format("+91980000%04d", n))
        Current.firm = firm
        create(:lead_project, firm:, lead: other, project_id: copy_id)
      end

      get "/api/v1/projects/#{copy_id}/marketplace_leads", headers:, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["leads"].size).to eq(25)
      expect(response.parsed_body["meta"]).to include("page" => 1, "per_page" => 25, "total_count" => 26, "total_pages" => 2)

      get "/api/v1/projects/#{copy_id}/marketplace_leads", params: { page: 2 }, headers:, as: :json

      expect(response.parsed_body["leads"].size).to eq(1)
      expect(response.parsed_body.dig("meta", "page")).to eq(2)
    end

    it "refuses a project the firm added itself" do
      own = create(:project, firm:, city:, external_ref: nil)

      get "/api/v1/projects/#{own.id}/marketplace_leads", headers:, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("not_marketplace")
    end
  end

  describe "POST /projects/:id/share_link" do
    let!(:catalog) { catalog_project(locality:) }
    let(:headers) { auth(broker) }

    before do
      allow(Realtoriq::Credentials).to receive(:turbo_public_origin).and_return("https://launch.example")
    end

    it "returns the marketplace url when asked from the firm's copy" do
      Current.firm = firm
      copy = Inventory::CopyCatalogProject.new(catalog:).call.project

      post "/api/v1/projects/#{copy.id}/share_link", headers:, as: :json

      expect(response).to have_http_status(:ok)
      url = response.parsed_body.dig("share_link", "url")
      expect(url).to start_with("https://launch.example/m/#{catalog.external_ref}?share_token=")
      token = response.parsed_body.dig("share_link", "token")

      post "/api/v1/projects/#{copy.id}/share_link", headers:, as: :json

      expect(response.parsed_body.dig("share_link", "token")).to eq(token)
    end
  end
end
