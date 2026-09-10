# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 dashboard" do
  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:manager) { create(:user, :manager, firm:) }
  let!(:agent) { create(:user, firm:, role: :agent) }

  let(:hot) { create(:lead_status, code: "hot", name: "Hot") }
  let(:followup) { create(:lead_status, code: "followup", name: "Followup") }

  def auth(as: manager)
    post "/api/v1/auth/otp", params: { mobile: as.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify", params: { request_id:, code: deliverer.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
  end

  def deliverer = Notifications::Deliverer.current

  describe "GET /api/v1/dashboard" do
    # The clock is frozen at mid-morning so "later today" and "earlier today"
    # both mean something fixed. Without that, a followup set for noon is in the
    # future before lunch and overdue after it, and the test changes meaning
    # with the hour it runs at.
    it "counts the lead pipeline in one request" do
      travel_to Time.zone.local(2026, 9, 10, 10, 0) do
        create(:lead, firm:, lead_status: hot, assigned_user: manager)
        create(:lead, firm:, lead_status: hot, assigned_user: agent)
        create(:lead, firm:, lead_status: followup, assigned_user: agent,
                     next_action_at: 2.days.ago)
        create(:lead, firm:, lead_status: followup, assigned_user: agent,
                     next_action_at: Time.current + 4.hours)
        create(:lead, firm:, lead_status: followup, first_visit_at: 3.days.ago)

        get "/api/v1/dashboard", headers: auth

        expect(response).to have_http_status(:ok)
        leads = response.parsed_body["leads"]
        expect(leads["total"]).to eq(5)
        expect(leads["hot"]).to eq(2)
        expect(leads["missed_followups"]).to eq(1)
        expect(leads["todays_followups"]).to eq(1)
        expect(leads["visited"]).to eq(1)
      end
    end

    # Deliberate, and worth pinning: a followup due at 10am is still "today's"
    # at 5pm *and* already overdue. The tiles deep-link to the leads list, and
    # `status=missed_followup` there uses the same `< now` rule — so a tile that
    # disagreed with the list it opens would be the real bug.
    it "counts a followup earlier today as both today's and missed" do
      travel_to Time.zone.local(2026, 9, 10, 17, 0) do
        create(:lead, firm:, lead_status: followup,
                     next_action_at: Time.zone.local(2026, 9, 10, 10, 0))

        get "/api/v1/dashboard", headers: auth

        leads = response.parsed_body["leads"]
        expect(leads["todays_followups"]).to eq(1)
        expect(leads["missed_followups"]).to eq(1)
      end
    end

    it "returns the three leads at the top of the worklist" do
      create_list(:lead, 5, firm:, lead_status: followup)

      get "/api/v1/dashboard", headers: auth

      expect(response.parsed_body.dig("leads", "recent").length).to eq(3)
    end

    it "sums revenue and brokerage over live bookings" do
      lead = create(:lead, firm:, lead_status: followup)
      create(:booking, firm:, lead:, agreement_value: 15_600_000,
                       commission_percent: 4.5, kicker: 50_000, passback: 66_000)

      get "/api/v1/dashboard", headers: auth

      money = response.parsed_body["money"]
      expect(money["revenue_till_date"]).to eq(15_600_000)
      # The design's worked example: 4.5% of 1.56 Cr, +50k, -66k.
      expect(money["brokerage_earned"]).to eq(686_000)
      expect(money["bookings_count"]).to eq(1)
    end

    it "does not inflate totals when a booking has several invoices" do
      # The bug this guards: summing over a scope carrying `includes` becomes a
      # LEFT JOIN and counts the booking once per invoice. It once reported
      # ₹3.12 Cr against a true ₹1.56 Cr.
      lead = create(:lead, firm:, lead_status: followup)
      booking = create(:booking, firm:, lead:, agreement_value: 15_600_000,
                                 commission_percent: 4.5, kicker: 50_000, passback: 66_000)
      create(:invoice, firm:, booking:, amount: 300_000)
      create(:invoice, firm:, booking:, amount: 200_000)
      create(:collection, firm:, booking:, amount: 120_000)
      create(:collection, firm:, booking:, amount: 80_000)

      get "/api/v1/dashboard", headers: auth

      money = response.parsed_body["money"]
      expect(money["revenue_till_date"]).to eq(15_600_000)
      expect(money["brokerage_earned"]).to eq(686_000)
      expect(money["invoiced"]).to eq(500_000)
      expect(money["collected"]).to eq(200_000)
      expect(money["outstanding"]).to eq(300_000)
    end

    it "excludes cancelled bookings from revenue and reports them separately" do
      lead = create(:lead, firm:, lead_status: followup)
      create(:booking, firm:, lead:, agreement_value: 15_600_000)
      create(:booking, :cancelled, firm:, lead:, agreement_value: 9_000_000)

      get "/api/v1/dashboard", headers: auth

      money = response.parsed_body["money"]
      expect(money["revenue_till_date"]).to eq(15_600_000)
      expect(money["bookings_count"]).to eq(1)
      expect(money.dig("cancelled", "count")).to eq(1)
      expect(money.dig("cancelled", "value")).to eq(9_000_000)
    end

    it "splits by the Indian financial year, not the calendar year" do
      lead = create(:lead, firm:, lead_status: followup)
      # 1 April is the first day of an FY; 31 March is the last day of the one
      # before. A calendar-year split would put these together.
      create(:booking, firm:, lead:, booked_on: Date.new(2026, 4, 1), agreement_value: 10_000_000)
      create(:booking, firm:, lead:, booked_on: Date.new(2026, 3, 31), agreement_value: 90_000_000)

      travel_to(Date.new(2026, 9, 10)) { get "/api/v1/dashboard", headers: auth }

      fy = response.parsed_body.dig("money", "this_fy")
      expect(fy["label"]).to eq("2026-27")
      expect(fy["starts_on"]).to eq("2026-04-01")
      expect(fy["ends_on"]).to eq("2027-03-31")
      expect(fy["revenue"]).to eq(10_000_000)
    end

    it "counts only registered bookings in the registered tile" do
      lead = create(:lead, firm:, lead_status: followup)
      create(:booking, firm:, lead:, agreement_value: 10_000_000,
                       registration_done_on: Date.current)
      create(:booking, firm:, lead:, agreement_value: 20_000_000)

      get "/api/v1/dashboard", headers: auth

      expect(response.parsed_body.dig("money", "registered", "count")).to eq(1)
      expect(response.parsed_body.dig("money", "registered", "value")).to eq(10_000_000)
    end

    it "reports inventory for the strip on the home screen" do
      create_list(:property, 2, firm:)
      create(:property, firm:, created_at: 3.weeks.ago)

      get "/api/v1/dashboard", headers: auth

      inventory = response.parsed_body["inventory"]
      expect(inventory["properties"]).to eq(3)
      expect(inventory["properties_added_this_week"]).to eq(2)
    end

    describe "an agent" do
      it "sees only their own leads in the counters" do
        create(:lead, firm:, lead_status: hot, assigned_user: agent)
        create(:lead, firm:, lead_status: hot, assigned_user: manager)
        create(:lead, firm:, lead_status: hot)

        get "/api/v1/dashboard", headers: auth(as: agent)

        expect(response.parsed_body.dig("leads", "total")).to eq(1)
      end

      it "gets no money block at all, rather than one full of zeroes" do
        lead = create(:lead, firm:, lead_status: followup)
        create(:booking, firm:, lead:, agreement_value: 15_600_000)

        get "/api/v1/dashboard", headers: auth(as: agent)

        expect(response).to have_http_status(:ok)
        # Zeroes would read as "no revenue" — a different and wrong statement,
        # and one an agent could screenshot.
        expect(response.parsed_body).not_to have_key("money")
        expect(response.parsed_body).to have_key("leads")
      end
    end

    it "keeps another firm's numbers out" do
      other = create(:firm, status: :active)
      create(:subscription, firm: other, plan:)
      other_lead = create(:lead, firm: other, lead_status: hot)
      create(:booking, firm: other, lead: other_lead, agreement_value: 99_000_000)
      create_list(:property, 4, firm: other)

      get "/api/v1/dashboard", headers: auth

      expect(response.parsed_body.dig("leads", "total")).to eq(0)
      expect(response.parsed_body.dig("money", "revenue_till_date")).to eq(0)
      expect(response.parsed_body.dig("inventory", "properties")).to eq(0)
    end

    it "needs a token" do
      get "/api/v1/dashboard"

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
