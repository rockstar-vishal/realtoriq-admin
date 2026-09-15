# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 users" do
  let(:plan) { create(:plan, max_users: 5) }
  let(:firm) { create(:firm, status: :active) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:super_admin) { create(:user, :super_admin, firm:) }
  let!(:manager) { create(:user, :manager, firm:) }
  let!(:agent) { create(:user, firm:, role: :agent) }

  def auth(user)
    post "/api/v1/auth/otp", params: { mobile: user.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify", params: { request_id:, code: deliverer.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
  end

  describe "GET /users" do
    before { create(:user_manager, user: agent, manager:, firm:) }

    it "lists the whole firm for the super admin, including disabled people" do
      disabled = create(:user, :disabled, firm:)

      get "/api/v1/users", headers: auth(super_admin)

      ids = response.parsed_body["users"].map { |row| row["id"] }
      expect(response).to have_http_status(:ok)
      expect(ids).to include(super_admin.id, manager.id, agent.id, disabled.id)
      expect(response.parsed_body["users"].find { |row| row["id"] == agent.id }["managers"])
        .to contain_exactly(hash_including("id" => manager.id, "role" => "manager"))
    end

    it "lists only active manageables for a manager" do
      outsider = create(:user, firm:, role: :agent)
      disabled_report = create(:user, :disabled, firm:)
      create(:user_manager, user: disabled_report, manager:, firm:)

      get "/api/v1/users", headers: auth(manager)

      ids = response.parsed_body["users"].map { |row| row["id"] }
      expect(ids).to contain_exactly(manager.id, agent.id)
      expect(ids).not_to include(outsider.id, disabled_report.id, super_admin.id)
    end

    it "does not query per person as the team grows" do
      headers = auth(super_admin)
      get "/api/v1/users", headers: headers

      small = count_sql_queries { get "/api/v1/users", headers: headers }

      8.times do
        report = create(:user, firm:)
        create(:user_manager, user: report, manager:, firm:)
      end

      large = count_sql_queries { get "/api/v1/users", headers: headers }
      expect(large).to eq(small)
    end
  end

  describe "POST /users" do
    def create_attrs(overrides = {})
      {
        name: "Priya Mehta",
        mobile: "9820199001",
        role: "agent"
      }.merge(overrides)
    end

    it "creates an agent who can sign in immediately" do
      post "/api/v1/users", params: create_attrs, headers: auth(super_admin), as: :json

      expect(response).to have_http_status(:created)
      body = response.parsed_body["user"]
      expect(body["role"]).to eq("agent")
      expect(body["mobile"]).to eq("+919820199001")
      expect(body["active"]).to be(true)
    end

    it "attaches managers supplied at create" do
      post "/api/v1/users",
        params: create_attrs(manager_ids: [ manager.id ]),
        headers: auth(super_admin), as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("user", "managers").map { |row| row["id"] }).to eq([ manager.id ])
    end

    it "refuses a second super admin" do
      post "/api/v1/users", params: create_attrs(role: "super_admin"),
        headers: auth(super_admin), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("invalid")
    end

    it "refuses a manager" do
      post "/api/v1/users", params: create_attrs, headers: auth(manager), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("forbidden_role")
    end

    it "counts disabled users toward the plan limit" do
      plan.update!(max_users: 4)
      create(:user, :disabled, firm:)

      post "/api/v1/users", params: create_attrs, headers: auth(super_admin), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("user_limit_reached")
    end

    it "treats a nil max_users as unlimited" do
      plan.update!(max_users: nil)

      post "/api/v1/users", params: create_attrs, headers: auth(super_admin), as: :json

      expect(response).to have_http_status(:created)
    end
  end

  describe "PATCH /users/:id" do
    it "disables a user and revokes their sessions" do
      headers_for_agent = auth(agent)
      get "/api/v1/me", headers: headers_for_agent
      expect(response).to have_http_status(:ok)

      patch "/api/v1/users/#{agent.id}", params: { status: "disabled" },
        headers: auth(super_admin), as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("user", "status")).to eq("disabled")
      expect(agent.auth_sessions.where(revoked_at: nil)).to be_empty

      get "/api/v1/me", headers: headers_for_agent
      expect(response).to have_http_status(:unauthorized)
    end

    it "re-enables a disabled user" do
      agent.update!(status: :disabled)

      patch "/api/v1/users/#{agent.id}", params: { status: "active" },
        headers: auth(super_admin), as: :json

      expect(response.parsed_body.dig("user", "active")).to be(true)
    end

    it "refuses to promote anyone to super admin" do
      patch "/api/v1/users/#{manager.id}", params: { role: "super_admin" },
        headers: auth(super_admin), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(manager.reload.role).to eq("manager")
    end

    it "refuses to disable or demote the super admin" do
      patch "/api/v1/users/#{super_admin.id}", params: { status: "disabled" },
        headers: auth(super_admin), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(super_admin.reload).to be_active
    end

    it "changes an agent's role to manager" do
      patch "/api/v1/users/#{agent.id}", params: { role: "manager" },
        headers: auth(super_admin), as: :json

      expect(response.parsed_body.dig("user", "role")).to eq("manager")
    end
  end

  describe "POST/DELETE /users/:id/managers" do
    it "adds and removes a reporting line" do
      headers = auth(super_admin)

      post "/api/v1/users/#{agent.id}/managers", params: { manager_id: manager.id },
        headers:, as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("user", "managers").map { |row| row["id"] }).to eq([ manager.id ])

      delete "/api/v1/users/#{agent.id}/managers/#{manager.id}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("user", "managers")).to eq([])
    end

    it "rejects a cycle with reporting_cycle" do
      create(:user_manager, user: agent, manager:, firm:)

      post "/api/v1/users/#{manager.id}/managers", params: { manager_id: agent.id },
        headers: auth(super_admin), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("reporting_cycle")
    end

    it "rejects a manager from another firm" do
      stranger = create(:user, :manager, firm: create(:firm))

      post "/api/v1/users/#{agent.id}/managers", params: { manager_id: stranger.id },
        headers: auth(super_admin), as: :json

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig("error", "code")).to eq("unknown_user")
    end

    it "is super-admin only" do
      post "/api/v1/users/#{agent.id}/managers", params: { manager_id: manager.id },
        headers: auth(manager), as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end
end
