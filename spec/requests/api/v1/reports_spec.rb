# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 reports" do
  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:manager) { create(:user, :manager, firm:) }
  let!(:agent) { create(:user, firm:, role: :agent) }
  let!(:disabled) { create(:user, :disabled, firm:) }

  let!(:hot) { create(:lead_status, :hot, code: "hot") }
  let!(:dead) { create(:lead_status, :dead, code: "dead") }
  let!(:referral) { create(:lead_source, name: "Referral", sort_order: 1) }
  let!(:portal) { create(:lead_source, name: "99acres", sort_order: 0) }
  let!(:under_construction) { create(:property_type, name: "Under construction") }

  def auth(as: manager)
    post "/api/v1/auth/otp", params: { mobile: as.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify", params: { request_id:, code: deliverer.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
  end

  def deliverer = Notifications::Deliverer.current

  def stamp(lead, time)
    lead.update_columns(created_at: time, updated_at: time)
  end

  def die(lead, at:, from: hot)
    LeadStatusChange.create!(
      firm: lead.firm, lead:, from_status: from, to_status: dead, changed_at: at
    )
  end

  describe "GET /api/v1/reports/source_status" do
    it "counts leads by current source and status inside an IST window" do
      inside = Time.find_zone("Asia/Kolkata").local(2026, 4, 1, 0, 30)
      referral_lead = create(:lead, firm:, lead_status: hot, lead_source: referral, assigned_user: agent)
      portal_lead = create(:lead, firm:, lead_status: dead, lead_source: portal, assigned_user: manager,
        dead_reason: "Price")
      unsourced = create(:lead, firm:, lead_status: hot, lead_source: nil, assigned_user: manager)
      outside = create(:lead, firm:, lead_status: hot, lead_source: referral)
      stamp(referral_lead, inside)
      stamp(portal_lead, inside)
      stamp(unsourced, inside)
      stamp(outside, Time.find_zone("Asia/Kolkata").local(2026, 3, 31, 23, 0))
      other = create(:firm, status: :active)
      create(:subscription, firm: other, plan:)
      foreign = create(:lead, firm: other, lead_status: hot, lead_source: referral)
      stamp(foreign, inside)

      get "/api/v1/reports/source_status",
        params: { from: "2026-04-01", upto: "2026-04-01" }, headers: auth

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["columns"].map { |column| column["code"] }).to eq(%w[hot dead])
      portal_row = body["rows"].find { |row| row.dig("source", "name") == "99acres" }
      referral_row = body["rows"].find { |row| row.dig("source", "name") == "Referral" }
      none = body["rows"].find { |row| row["source"]["id"].nil? }
      expect(portal_row["counts"]).to include("dead" => 1, "hot" => 0)
      expect(referral_row["counts"]).to include("hot" => 1, "dead" => 0)
      expect(none["total"]).to eq(1)
      expect(body.dig("summary", "total")).to eq(3)
    end

    it "does not let an agent widen the report to someone else's leads" do
      create(:lead, firm:, lead_status: hot, lead_source: referral, assigned_user: agent)
      create(:lead, firm:, lead_status: hot, lead_source: referral, assigned_user: manager)

      get "/api/v1/reports/source_status",
        params: { from: "2020-01-01", upto: "2030-01-01", assigned_user_id: manager.id },
        headers: auth(as: agent)

      expect(response.parsed_body.dig("summary", "total")).to eq(0)
    end

    it "returns nothing for rent combined with a property type" do
      create(:lead, :rent, firm:, lead_status: hot, lead_source: referral)
      create(:lead, firm:, lead_status: hot, lead_source: referral, property_type: under_construction)

      get "/api/v1/reports/source_status",
        params: {
          from: "2020-01-01", upto: "2030-01-01",
          transaction_type: "rent", property_type_id: under_construction.id
        },
        headers: auth

      expect(response.parsed_body.dig("summary", "total")).to eq(0)
    end

    it "rejects a reversed range" do
      get "/api/v1/reports/source_status",
        params: { from: "2026-04-02", upto: "2026-04-01" }, headers: auth

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("invalid")
    end

    it "downloads the same totals as csv" do
      lead = create(:lead, firm:, lead_status: hot, lead_source: referral)
      stamp(lead, Time.find_zone("Asia/Kolkata").local(2026, 4, 2, 12, 0))

      get "/api/v1/reports/source_status",
        params: { from: "2026-04-01", upto: "2026-04-30", export: "csv" }, headers: auth

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/csv")
      expect(response.body).to include("Referral")
      expect(response.body).to include("All sources")
    end
  end

  describe "GET /api/v1/reports/dead_leads" do
    it "counts a death from the history row after the lead is revived, and rates the summary from the totals" do
      zone = Time.find_zone("Asia/Kolkata")
      august = create(:lead, firm:, lead_status: dead, lead_source: referral, dead_reason: "Price")
      stamp(august, zone.local(2026, 8, 10, 9, 0))
      die(august, at: zone.local(2026, 9, 5, 9, 0))

      july = create(:lead, firm:, lead_status: hot, lead_source: portal)
      stamp(july, zone.local(2026, 7, 2, 9, 0))
      die(july, at: zone.local(2026, 9, 20, 9, 0))
      july.update_columns(lead_status_id: hot.id, dead_at: nil, dead_reason: nil)

      get "/api/v1/reports/dead_leads",
        params: { from: "2026-08-01", upto: "2026-09-30" }, headers: auth

      rows = response.parsed_body["rows"]
      august_row = rows.find { |row| row["month"] == "2026-08" }
      september = rows.find { |row| row["month"] == "2026-09" }
      expect(august_row).to include("generated" => 1, "dead" => 0, "rate" => 0)
      expect(september).to include("generated" => 0, "dead" => 2, "rate" => nil)
      expect(september["by_source"][referral.id]).to eq(1)
      expect(response.parsed_body["summary"]).to include("generated" => 1, "dead" => 2, "rate" => 200)
    end

    it "puts a lead created at 00:30 IST on 1 April into April, not March" do
      lead = create(:lead, firm:, lead_status: hot, lead_source: referral)
      stamp(lead, Time.find_zone("Asia/Kolkata").local(2026, 4, 1, 0, 30))

      get "/api/v1/reports/dead_leads",
        params: { from: "2026-03-31", upto: "2026-03-31" }, headers: auth
      expect(response.parsed_body.dig("summary", "generated")).to eq(0)

      get "/api/v1/reports/dead_leads",
        params: { from: "2026-04-01", upto: "2026-04-01" }, headers: auth
      april = response.parsed_body["rows"].find { |row| row["label"] == "Apr 2026" }
      expect(april["generated"]).to eq(1)
    end
  end

  describe "GET /api/v1/reports/bookings" do
    it "keeps cancelled bookings out of the rupees and does not multiply a booking by its invoices" do
      lead = create(:lead, firm:, lead_status: hot)
      live = create(:booking, firm:, lead:, booked_on: Date.new(2026, 9, 10),
        agreement_value: 1_000_000, commission_percent: 0, kicker: 0, passback: 0)
      create(:invoice, firm:, booking: live, amount: 100_000, issued_on: Date.new(2026, 10, 1))
      create(:invoice, firm:, booking: live, amount: 50_000, issued_on: Date.new(2026, 11, 1))
      create(:collection, firm:, booking: live, amount: 40_000, received_on: Date.new(2026, 12, 1))
      cancelled = create(:booking, :cancelled, firm:, lead:, booked_on: Date.new(2026, 9, 12),
        agreement_value: 9_000_000)
      create(:invoice, firm:, booking: cancelled, amount: 500_000)

      get "/api/v1/reports/bookings",
        params: { from: "2026-09-01", upto: "2026-09-30", status: "dead" }, headers: auth

      row = response.parsed_body["rows"].find { |item| item["month"] == "2026-09" }
      expect(row).to include(
        "bookings" => 2, "cancelled" => 1, "live" => 1,
        "agreement_value" => 1_000_000, "invoices" => 2, "collections" => 1
      )
    end

    it "is forbidden for an agent" do
      get "/api/v1/reports/bookings", headers: auth(as: agent)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("forbidden_role")
    end
  end

  describe "GET /api/v1/reports/revenue" do
    it "sums stored net income, including a negative one, and outstanding is invoiced minus collected" do
      lead = create(:lead, firm:, lead_status: hot)
      create(:booking, firm:, lead:, booked_on: Date.new(2026, 9, 4),
        agreement_value: 1_000, commission_percent: 0, kicker: 0, passback: 50)
      positive = create(:booking, firm:, lead:, booked_on: Date.new(2026, 9, 8),
        agreement_value: 10_000, commission_percent: 10, kicker: 0, passback: 0)
      create(:invoice, firm:, booking: positive, amount: 800)
      create(:collection, firm:, booking: positive, amount: 300)

      get "/api/v1/reports/revenue",
        params: { from: "2026-09-01", upto: "2026-09-30" }, headers: auth

      summary = response.parsed_body["summary"]
      expect(summary["agreement_value"]).to eq(11_000)
      expect(summary["net_income"]).to eq(950)
      expect(summary["invoiced"]).to eq(800)
      expect(summary["collected"]).to eq(300)
      expect(summary["outstanding"]).to eq(500)
    end

    it "is forbidden for an agent" do
      get "/api/v1/reports/revenue", headers: auth(as: agent)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /api/v1/reports/assignees" do
    it "lists the whole firm for a manager and only the caller for an agent" do
      get "/api/v1/reports/assignees", headers: auth
      ids = response.parsed_body["users"].map { |user| user["id"] }
      expect(ids).to include(manager.id, agent.id, disabled.id)

      get "/api/v1/reports/assignees", headers: auth(as: agent)
      expect(response.parsed_body["users"].map { |user| user["id"] }).to eq([ agent.id ])
    end
  end

  describe "GET /api/v1/leads drill-down filters" do
    it "filters by the IST created range, a death, several sources, and no source" do
      zone = Time.find_zone("Asia/Kolkata")
      early = create(:lead, firm:, lead_status: hot, lead_source: referral)
      stamp(early, zone.local(2026, 1, 2, 10, 0))
      recent = create(:lead, firm:, lead_status: hot, lead_source: portal)
      stamp(recent, zone.local(2026, 4, 2, 10, 0))
      bare = create(:lead, firm:, lead_status: hot, lead_source: nil)
      stamp(bare, zone.local(2026, 4, 3, 10, 0))
      revived = create(:lead, firm:, lead_status: hot, lead_source: referral)
      stamp(revived, zone.local(2025, 1, 1, 10, 0))
      die(revived, at: zone.local(2026, 4, 4, 10, 0))

      headers = auth
      get "/api/v1/leads", params: { created_from: "2026-04-01", created_upto: "2026-04-30" }, headers: headers
      expect(response.parsed_body["leads"].map { |lead| lead["id"] }).to contain_exactly(recent.id, bare.id)

      get "/api/v1/leads",
        params: { source_id: [ referral.id, portal.id ], source_missing: true, created_from: "2026-04-01", created_upto: "2026-04-30" },
        headers: headers
      expect(response.parsed_body["leads"].map { |lead| lead["id"] }).to contain_exactly(recent.id, bare.id)

      get "/api/v1/leads", params: { died_from: "2026-04-01", died_upto: "2026-04-30" }, headers: headers
      expect(response.parsed_body["leads"].map { |lead| lead["id"] }).to eq([ revived.id ])
    end

    it "accepts several property types and assignees" do
      ready = create(:property_type, name: "Ready possession")
      first = create(:lead, firm:, lead_status: hot, property_type: under_construction, assigned_user: agent)
      second = create(:lead, firm:, lead_status: hot, property_type: ready, assigned_user: manager)
      create(:lead, :rent, firm:, lead_status: hot, assigned_user: manager)

      get "/api/v1/leads",
        params: { property_type_id: [ under_construction.id, ready.id ], assigned_user_id: [ agent.id, manager.id ] },
        headers: auth

      expect(response.parsed_body["leads"].map { |lead| lead["id"] }).to contain_exactly(first.id, second.id)
    end

    it "rejects a created range that runs backwards" do
      get "/api/v1/leads",
        params: { created_from: "2026-05-02", created_upto: "2026-05-01" }, headers: auth

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("invalid")
    end
  end
end
