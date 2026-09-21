# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 leads" do
  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active) }
  let!(:subscription) { create(:subscription, firm:, plan:) }

  let!(:super_admin) { create(:user, :super_admin, firm:) }
  let!(:manager) { create(:user, :manager, firm:) }
  let!(:agent) { create(:user, firm:, role: :agent) }

  let!(:new_status) { create(:lead_status, :new_lead) }
  let!(:dead_status) { create(:lead_status, :dead) }
  let!(:property_type) { create(:property_type) }

  def auth(user)
    post "/api/v1/auth/otp", params: { mobile: user.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify", params: { request_id:, code: deliverer.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
  end

  def valid_attributes(overrides = {})
    {
      name: "Rhea Kapoor", mobile: "98201 44210", transaction_type: "sale",
      property_type_id: property_type.id, budget: 16_000_000
    }.merge(overrides)
  end

  describe "POST /leads" do
    it "creates a lead and opens its status history" do
      headers = auth(manager)

      # across_firms because the spec has no Current.firm — the fail-closed
      # default scope would otherwise count zero on both sides and pass for
      # the wrong reason.
      expect {
        post "/api/v1/leads", params: valid_attributes, headers: headers, as: :json
      }.to change { Lead.across_firms.count }.by(1)

      body = response.parsed_body
      expect(response).to have_http_status(:created)
      expect(body.dig("lead", "code")).to eq("L-0001")
      expect(body.dig("lead", "status", "name")).to eq("New")
      # The opening row exists so the dead-leads report can see when the lead
      # entered the pipeline, not only when it left.
      expect(body.dig("lead", "status_history").size).to eq(1)
      expect(body.dig("lead", "budget")).to eq(16_000_000)
      expect(body.dig("lead", "budget_max")).to eq(16_000_000)
      expect(body.dig("lead", "budget_min")).to be_nil
    end

    it "ignores budget_min on write" do
      post "/api/v1/leads",
        params: valid_attributes.except(:budget).merge(budget_min: 12_000_000, budget_max: 18_000_000),
        headers: auth(manager), as: :json

      body = response.parsed_body["lead"]
      expect(response).to have_http_status(:created)
      expect(body["budget"]).to be_nil
      expect(body["budget_min"]).to be_nil
      expect(body["budget_max"]).to be_nil
    end

    it "normalises the mobile" do
      post "/api/v1/leads", params: valid_attributes(mobile: "098201 44210"),
        headers: auth(manager), as: :json

      expect(response.parsed_body.dig("lead", "mobile")).to eq("+919820144210")
    end

    it "attaches the preferred configurations" do
      typologies = create_list(:typology, 2)

      post "/api/v1/leads",
        params: valid_attributes(typology_ids: typologies.map(&:id)),
        headers: auth(manager), as: :json

      expect(response.parsed_body.dig("lead", "typologies").size).to eq(2)
    end

    it "accepts a lead with no name" do
      post "/api/v1/leads", params: valid_attributes(name: nil), headers: auth(manager), as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("lead", "display_name")).to eq("+91 98201 44210")
    end

    it "refuses a sale lead with no property type" do
      post "/api/v1/leads", params: valid_attributes(property_type_id: nil),
        headers: auth(manager), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "message")).to match(/required for a sale lead/)
    end

    it "refuses a rental lead carrying a property type" do
      post "/api/v1/leads",
        params: valid_attributes(transaction_type: "rent"),
        headers: auth(manager), as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "assigns an agent's own lead to them, or they'd never see it again" do
      post "/api/v1/leads", params: valid_attributes, headers: auth(agent), as: :json

      expect(response.parsed_body.dig("lead", "assigned_user", "id")).to eq(agent.id)
    end

    it "leaves a manager's lead unassigned unless they say otherwise" do
      post "/api/v1/leads", params: valid_attributes, headers: auth(manager), as: :json

      expect(response.parsed_body.dig("lead", "assigned_user")).to be_nil
    end

    it "assigns a manager's lead to someone in their line when they ask" do
      create(:user_manager, user: agent, manager:, firm:)

      post "/api/v1/leads", params: valid_attributes(assigned_user_id: agent.id),
        headers: auth(manager), as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("lead", "assigned_user", "id")).to eq(agent.id)
    end

    it "refuses a manager assigning to someone outside their line" do
      outsider = create(:user, firm:, role: :agent)

      post "/api/v1/leads", params: valid_attributes(assigned_user_id: outsider.id),
        headers: auth(manager), as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "refuses a second sale lead on the same number and names the existing one" do
      headers = auth(manager)
      post "/api/v1/leads", params: valid_attributes, headers: headers, as: :json
      existing_id = response.parsed_body.dig("lead", "id")

      post "/api/v1/leads", params: valid_attributes(name: "Rhea K."), headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("duplicate_lead")
      expect(response.parsed_body.dig("error", "details", "lead_id")).to eq(existing_id)
    end

    it "allows the same number once as sale and once as rent" do
      headers = auth(manager)
      post "/api/v1/leads", params: valid_attributes, headers: headers, as: :json

      post "/api/v1/leads",
        params: valid_attributes(transaction_type: "rent", property_type_id: nil, name: "Rhea rent"),
        headers: headers, as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("lead", "transaction_type")).to eq("rent")
      expect(response.parsed_body["possible_duplicates"].size).to eq(1)
    end

    it "copies budget and notes from a project and maps it" do
      project = create(:project, firm:, name: "From Project",
        starting_budget: 20_000_000, city: create(:city, name: "Thane"),
        locality: create(:locality, name: "Kolshet"))

      post "/api/v1/leads",
        params: valid_attributes(project_id: project.id, budget: nil, notes: nil),
        headers: auth(manager), as: :json

      expect(response).to have_http_status(:created)
      body = response.parsed_body["lead"]
      expect(body["budget"]).to eq(20_000_000)
      expect(body["budget_max"]).to eq(20_000_000)
      expect(body["budget_min"]).to be_nil
      expect(body["notes"]).to include("Client's requirements")
      expect(body["notes"]).to include("Kolshet")
      expect(body["mapped_projects"].map { |m| m.dig("project", "id") }).to eq([ project.id ])
    end
  end

  describe "GET /leads" do
    it "returns the firm's leads with pagination meta" do
      create_list(:lead, 3, firm:, lead_status: new_status)

      get "/api/v1/leads", headers: auth(manager)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["leads"].size).to eq(3)
      expect(response.parsed_body["counts"]).to include(
        "new" => 3, "missed_followup" => 0, "visit_planned" => 0,
        "visited" => 0, "hot_negotiation" => 0, "booked" => 0
      )
      expect(response.parsed_body["meta"]).to include("total_count" => 3, "per_page" => 25)
    end

    it "includes the list-card fields: source, visit count, last followup, created_at" do
      source = create(:lead_source, name: "99acres")
      lead = create(:lead, firm:, lead_status: new_status, lead_source: source,
                           property_type:, first_visit_at: 3.days.ago)
      create(:lead_activity, firm:, lead:, kind: "visit", body: "First site visit",
                             occurred_at: 3.days.ago)
      create(:lead_activity, firm:, lead:, kind: "visit", body: "Second site visit",
                             occurred_at: 2.days.ago)
      create(:lead_activity, firm:, lead:, kind: "call", body: "Asked for the floor plan",
                             occurred_at: 1.day.ago)
      create(:lead_activity, firm:, lead:, kind: "status_change", body: nil,
                             occurred_at: Time.current)
      bare = create(:lead, firm:, lead_status: new_status, property_type:)

      get "/api/v1/leads", headers: auth(manager)

      card = response.parsed_body["leads"].find { |row| row["id"] == lead.id }
      expect(card["source"]).to include("id" => source.id, "name" => "99acres")
      expect(card["visit_count"]).to eq(2)
      expect(card["visited"]).to be(true)
      expect(card["last_followup_comment"]).to eq("Asked for the floor plan")
      expect(card["created_at"]).to be_present
      expect(card["transaction_type"]).to eq("sale")
      expect(card["property_type"]).to include("id" => property_type.id)

      empty = response.parsed_body["leads"].find { |row| row["id"] == bare.id }
      expect(empty["source"]).to be_nil
      expect(empty["visit_count"]).to eq(0)
      expect(empty["last_followup_comment"]).to be_nil
    end

    it "defaults to 25 per page rather than 1 when the param is absent" do
      create_list(:lead, 2, firm:, lead_status: new_status)

      get "/api/v1/leads", headers: auth(manager)

      expect(response.parsed_body["leads"].size).to eq(2)
    end

    it "caps per_page" do
      get "/api/v1/leads", params: { per_page: 500 }, headers: auth(manager)

      expect(response.parsed_body.dig("meta", "per_page")).to eq(50)
    end

    it "searches name, mobile and email" do
      target = create(:lead, firm:, lead_status: new_status, name: "Findable Person")
      create(:lead, firm:, lead_status: new_status, name: "Someone Else")

      get "/api/v1/leads", params: { q: "Findable" }, headers: auth(manager)

      expect(response.parsed_body["leads"].map { |l| l["id"] }).to eq([ target.id ])
    end

    it "filters to overdue followups through the derived tab" do
      overdue = create(:lead, :overdue, firm:, lead_status: new_status)
      create(:lead, :upcoming, firm:, lead_status: new_status)

      get "/api/v1/leads", params: { status: "missed_followup" }, headers: auth(manager)

      expect(response.parsed_body["leads"].map { |l| l["id"] }).to eq([ overdue.id ])
      expect(response.parsed_body["leads"].first["overdue"]).to be(true)
    end

    it "defaults to next-action order with unset dates first" do
      create(:lead, :upcoming, firm:, lead_status: new_status, name: "Later")
      create(:lead, :overdue, firm:, lead_status: new_status, name: "Overdue")
      create(:lead, firm:, lead_status: new_status, name: "New", next_action_at: nil)

      get "/api/v1/leads", headers: auth(manager)

      expect(response.parsed_body["leads"].map { |l| l["name"] }).to eq(%w[New Overdue Later])
    end

    it "sorts overdue work to the top when sort=worklist" do
      create(:lead, firm:, lead_status: new_status, name: "New", next_action_at: nil)
      create(:lead, :overdue, firm:, lead_status: new_status, name: "Now")

      get "/api/v1/leads", params: { sort: "worklist" }, headers: auth(manager)

      expect(response.parsed_body["leads"].first["name"]).to eq("Now")
    end

    it "filters by the stored budget amount lying in the window" do
      in_window = create(:lead, firm:, lead_status: new_status,
        budget_min: nil, budget_max: 12_000_000)
      create(:lead, firm:, lead_status: new_status, budget_min: 8_000_000, budget_max: 9_000_000)

      get "/api/v1/leads", params: { budget_min: 10_000_000, budget_max: 13_000_000 },
        headers: auth(manager)

      expect(response.parsed_body["leads"].map { |l| l["id"] }).to eq([ in_window.id ])
    end

    it "ignores q when a drawer filter is present" do
      matching_q = create(:lead, firm:, lead_status: new_status, name: "Alpha Kapoor")
      matching_name = create(:lead, firm:, lead_status: new_status, name: "Beta Shah")

      get "/api/v1/leads", params: { q: "Alpha", name: "Beta" }, headers: auth(manager)

      expect(response.parsed_body["leads"].map { |l| l["id"] }).to eq([ matching_name.id ])
      expect(response.parsed_body["leads"].map { |l| l["id"] }).not_to include(matching_q.id)
    end

    it "still applies q when only a card filter is present" do
      matching = create(:lead, firm:, lead_status: new_status, name: "Alpha Kapoor")
      create(:lead, firm:, lead_status: new_status, name: "Beta Shah")

      get "/api/v1/leads", params: { q: "Alpha", status: "new" }, headers: auth(manager)

      expect(response.parsed_body["leads"].map { |l| l["id"] }).to eq([ matching.id ])
    end

    it "filters visited clients by first_visit_at" do
      visited = create(:lead, firm:, lead_status: new_status, first_visit_at: 1.day.ago)
      create(:lead, firm:, lead_status: new_status)

      get "/api/v1/leads", params: { visited: true }, headers: auth(manager)

      expect(response.parsed_body["leads"].map { |l| l["id"] }).to eq([ visited.id ])
    end

    it "filters hot and negotiation together" do
      hot_status = create(:lead_status, :hot)
      negotiation_status = create(:lead_status, :negotiation)
      hot = create(:lead, firm:, lead_status: hot_status)
      negotiation = create(:lead, firm:, lead_status: negotiation_status)
      create(:lead, firm:, lead_status: new_status)

      get "/api/v1/leads", params: { status: "hot_negotiation" }, headers: auth(manager)
      expect(response.parsed_body["leads"].map { |l| l["id"] }).to contain_exactly(hot.id, negotiation.id)

      get "/api/v1/leads", params: { status: %w[hot negotiation] }, headers: auth(manager)
      expect(response.parsed_body["leads"].map { |l| l["id"] }).to contain_exactly(hot.id, negotiation.id)
    end

    it "keeps card counts unfiltered while the list is filtered" do
      create(:lead, :overdue, firm:, lead_status: new_status, name: "Overdue New")
      create(:lead, firm:, lead_status: create(:lead_status, :booked))

      get "/api/v1/leads", params: { q: "no-such-lead" }, headers: auth(manager)

      expect(response.parsed_body["leads"]).to eq([])
      expect(response.parsed_body["counts"]).to include("new" => 1, "missed_followup" => 1, "booked" => 1)
    end
  end

  describe "visibility" do
    let!(:agents_lead) { create(:lead, firm:, lead_status: new_status, assigned_user: agent) }
    let!(:someone_elses) { create(:lead, firm:, lead_status: new_status, assigned_user: manager) }

    it "shows an agent only their own" do
      get "/api/v1/leads", headers: auth(agent)

      expect(response.parsed_body["leads"].map { |l| l["id"] }).to eq([ agents_lead.id ])
      expect(response.parsed_body.dig("counts", "new")).to eq(1)
    end

    it "shows a manager the whole pipeline" do
      get "/api/v1/leads", headers: auth(manager)

      expect(response.parsed_body["leads"].size).to eq(2)
    end

    it "returns 404, not 403, for a lead the agent may not see" do
      # A 403 would confirm the record exists.
      get "/api/v1/leads/#{someone_elses.id}", headers: auth(agent)

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 for another firm's lead" do
      other = create(:lead, firm: create(:firm), lead_status: new_status)

      get "/api/v1/leads/#{other.id}", headers: auth(super_admin)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /leads/:id assignment" do
    let!(:lead) { create(:lead, firm:, lead_status: new_status, assigned_user: agent) }

    before { create(:user_manager, user: agent, manager:, firm:) }

    it "lets a manager reassign within their active manageables" do
      patch "/api/v1/leads/#{lead.id}", params: { assigned_user_id: manager.id },
        headers: auth(manager), as: :json

      expect(response).to have_http_status(:ok)
      expect(lead.reload.assigned_user).to eq(manager)
    end

    it "lets a manager assign to an agent they manage" do
      patch "/api/v1/leads/#{lead.id}", params: { assigned_user_id: agent.id },
        headers: auth(manager), as: :json

      expect(response).to have_http_status(:ok)
      expect(lead.reload.assigned_user).to eq(agent)
    end

    it "refuses a firm user outside the manager's line" do
      outsider = create(:user, firm:, role: :agent)

      patch "/api/v1/leads/#{lead.id}", params: { assigned_user_id: outsider.id },
        headers: auth(manager), as: :json

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig("error", "code")).to eq("unknown_user")
      expect(lead.reload.assigned_user).to eq(agent)
    end

    it "refuses a disabled user even when they sit in the line" do
      agent.update!(status: :disabled)

      patch "/api/v1/leads/#{lead.id}", params: { assigned_user_id: agent.id },
        headers: auth(manager), as: :json

      expect(response).to have_http_status(:not_found)
      expect(lead.reload.assigned_user_id).to eq(agent.id)
    end

    it "lets the super admin assign anyone active in the firm" do
      outsider = create(:user, firm:, role: :agent)

      patch "/api/v1/leads/#{lead.id}", params: { assigned_user_id: outsider.id },
        headers: auth(super_admin), as: :json

      expect(response).to have_http_status(:ok)
      expect(lead.reload.assigned_user).to eq(outsider)
    end

    it "refuses a user from another firm" do
      stranger = create(:user, firm: create(:firm))

      patch "/api/v1/leads/#{lead.id}", params: { assigned_user_id: stranger.id },
        headers: auth(super_admin), as: :json

      expect(response).to have_http_status(:not_found)
      expect(lead.reload.assigned_user).to eq(agent)
    end

    it "lets a manager unassign" do
      patch "/api/v1/leads/#{lead.id}", params: { assigned_user_id: nil },
        headers: auth(manager), as: :json

      expect(response).to have_http_status(:ok)
      expect(lead.reload.assigned_user).to be_nil
    end

    it "refuses an agent unassigning — that would hide the lead from every agent" do
      patch "/api/v1/leads/#{lead.id}", params: { assigned_user_id: nil },
        headers: auth(agent), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("forbidden_role")
      expect(lead.reload.assigned_user_id).to eq(agent.id)
    end

    it "lets an agent reassign only inside their own line" do
      junior = create(:user, firm:, role: :agent)
      create(:user_manager, user: junior, manager: agent, firm:)

      patch "/api/v1/leads/#{lead.id}", params: { assigned_user_id: junior.id },
        headers: auth(agent), as: :json

      expect(response).to have_http_status(:ok)
      expect(lead.reload.assigned_user).to eq(junior)
    end

    it "does not let an agent hand a lead to someone they do not manage" do
      patch "/api/v1/leads/#{lead.id}", params: { assigned_user_id: manager.id, notes: "still mine" },
        headers: auth(agent), as: :json

      expect(response).to have_http_status(:not_found)
      expect(lead.reload.assigned_user_id).to eq(agent.id)
      expect(lead.notes).not_to eq("still mine")
    end

    it "leaves assignment alone when the key is omitted" do
      patch "/api/v1/leads/#{lead.id}", params: { notes: "call tomorrow" },
        headers: auth(agent), as: :json

      expect(response).to have_http_status(:ok)
      expect(lead.reload.assigned_user_id).to eq(agent.id)
      expect(lead.notes).to eq("call tomorrow")
    end

    it "writes budget to budget_max and clears budget_min" do
      lead.update!(budget_min: 8_000_000, budget_max: 12_000_000)

      patch "/api/v1/leads/#{lead.id}", params: { budget: 20_000_000 },
        headers: auth(manager), as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("lead", "budget")).to eq(20_000_000)
      expect(lead.reload.budget_min).to be_nil
      expect(lead.budget_max).to eq(20_000_000)
    end

    it "refuses flipping type when the other type already exists on that mobile" do
      create(:lead, :rent, firm:, mobile: lead.mobile, lead_status: new_status)

      patch "/api/v1/leads/#{lead.id}", params: { transaction_type: "rent", property_type_id: nil },
        headers: auth(manager), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("duplicate_lead")
      expect(lead.reload.transaction_type).to eq("sale")
    end

    it "no longer has POST /leads/:id/assign" do
      post "/api/v1/leads/#{lead.id}/assign", params: { assigned_user_id: manager.id },
        headers: auth(manager), as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /leads/:id/status" do
    let!(:lead) { create(:lead, firm:, lead_status: new_status) }

    it "refuses to mark a lead dead without a reason" do
      post "/api/v1/leads/#{lead.id}/status", params: { status: dead_status.code },
        headers: auth(manager), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("reason_required")
      expect(lead.reload.lead_status).to eq(new_status)
    end

    it "records the reason, the history row and a timeline entry" do
      post "/api/v1/leads/#{lead.id}/status",
        params: { status: dead_status.code, reason: "Bought elsewhere" },
        headers: auth(manager), as: :json

      expect(response).to have_http_status(:ok)
      lead.reload
      expect(lead.dead_reason).to eq("Bought elsewhere")
      expect(lead.dead_at).to be_present
      expect(lead.lead_status_changes.into_dead.count).to eq(1)
      expect(lead.lead_activities.status_change.count).to eq(1)
    end

    it "clears the death details when the lead is revived" do
      post "/api/v1/leads/#{lead.id}/status",
        params: { status: dead_status.code, reason: "Gone quiet" },
        headers: auth(manager), as: :json

      post "/api/v1/leads/#{lead.id}/status", params: { status: new_status.code },
        headers: auth(manager), as: :json

      lead.reload
      expect(lead.dead_reason).to be_nil
      expect(lead.dead_at).to be_nil
    end

    it "rejects an unknown status" do
      post "/api/v1/leads/#{lead.id}/status", params: { status: "nonsense" },
        headers: auth(manager), as: :json

      expect(response.parsed_body.dig("error", "code")).to eq("unknown_status")
    end
  end

  describe "activities" do
    let!(:lead) { create(:lead, firm:, lead_status: new_status, assigned_user: agent) }

    it "logs a call" do
      post "/api/v1/leads/#{lead.id}/activities",
        params: { kind: "call", body: "Discussed the 3 BHK" },
        headers: auth(agent), as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("activity", "kind")).to eq("call")
    end

    it "sets the visited badge from a visit, so the two cannot disagree" do
      post "/api/v1/leads/#{lead.id}/activities",
        params: { kind: "visit", body: "Site visit" },
        headers: auth(agent), as: :json

      expect(response.parsed_body.dig("lead", "visited")).to be(true)
      expect(response.parsed_body.dig("lead", "visit_count")).to eq(1)
      expect(response.parsed_body.dig("lead", "last_followup_comment")).to eq("Site visit")
      expect(lead.reload.first_visit_at).to be_present
    end

    it "keeps the earliest visit when an older one is logged later" do
      headers = auth(agent)
      post "/api/v1/leads/#{lead.id}/activities",
        params: { kind: "visit", body: "Recent", occurred_at: 1.day.ago },
        headers: headers, as: :json

      post "/api/v1/leads/#{lead.id}/activities",
        params: { kind: "visit", body: "Older", occurred_at: 10.days.ago },
        headers: headers, as: :json

      expect(lead.reload.first_visit_at).to be_within(1.minute).of(10.days.ago)
    end

    it "refuses a hand-written status_change" do
      # Pipeline movement goes through the status endpoint, which also writes
      # the reporting record.
      post "/api/v1/leads/#{lead.id}/activities",
        params: { kind: "status_change", body: "sneaky" },
        headers: auth(agent), as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns the timeline newest first" do
      headers = auth(agent)
      create(:lead_activity, firm:, lead:, body: "Older", occurred_at: 2.days.ago)
      create(:lead_activity, firm:, lead:, body: "Newer", occurred_at: 1.hour.ago)

      get "/api/v1/leads/#{lead.id}/activities", headers: headers

      expect(response.parsed_body["activities"].map { |a| a["body"] }).to eq([ "Newer", "Older" ])
    end
  end

  describe "a rejected update" do
    it "leaves the preferred configurations alone" do
      # replace_typologies deletes the join rows immediately, so without a
      # transaction a 422 destroyed data the caller never asked to change.
      typologies = create_list(:typology, 2)
      lead = create(:lead, firm:)
      typologies.each { |t| lead.lead_typologies.create!(typology: t) }
      headers = auth(super_admin)

      patch "/api/v1/leads/#{lead.id}", params: {
        typology_ids: [ typologies.first.id ], email: "not-an-email"
      }, headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(lead.reload.typologies.count).to eq(2)
    end

    it "leaves the other attributes alone too" do
      lead = create(:lead, firm:, name: "Original")

      patch "/api/v1/leads/#{lead.id}",
        params: { name: "Changed", email: "not-an-email" },
        headers: auth(super_admin), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(lead.reload.name).to eq("Original")
    end

    it "still replaces the set on a successful update" do
      typologies = create_list(:typology, 2)
      lead = create(:lead, firm:)
      typologies.each { |t| lead.lead_typologies.create!(typology: t) }

      patch "/api/v1/leads/#{lead.id}",
        params: { typology_ids: [ typologies.first.id ] }, headers: auth(super_admin), as: :json

      expect(response).to have_http_status(:ok)
      expect(lead.reload.typologies.map(&:id)).to eq([ typologies.first.id ])
    end
  end
end
