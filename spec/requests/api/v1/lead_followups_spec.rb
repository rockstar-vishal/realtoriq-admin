# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 lead followups" do
  include ActiveSupport::Testing::TimeHelpers

  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:manager) { create(:user, :manager, firm:) }
  let!(:agent) { create(:user, firm:, role: :agent) }
  let!(:new_status) { create(:lead_status, :new_lead) }
  let!(:hot_status) { create(:lead_status, :hot) }
  let!(:dead_status) { create(:lead_status, :dead) }
  let!(:booked_status) { create(:lead_status, :booked) }
  let!(:followup_status) { create(:lead_status, name: "Followup") }
  let!(:visit_status) { create(:lead_status, :visit_planned) }
  let!(:lead) { create(:lead, firm:, lead_status: new_status, assigned_user: agent) }

  def auth(user)
    post "/api/v1/auth/otp", params: { mobile: user.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify", params: { request_id:, code: deliverer.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
  end

  describe "POST /leads/:id/followups" do
    it "appends a second followup without changing the first" do
      headers = auth(agent)
      post "/api/v1/leads/#{lead.id}/followups",
        params: { comment: "First discussion", next_action_at: 2.days.from_now.iso8601 }, headers:, as: :json
      first_id = response.parsed_body.dig("followup", "id")

      post "/api/v1/leads/#{lead.id}/followups",
        params: { comment: "Second discussion", next_action_at: 3.days.from_now.iso8601 }, headers:, as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("followup", "comment")).to eq("Second discussion")
      expect(lead.lead_followups.order(:created_at).pluck(:comment))
        .to eq([ "First discussion", "Second discussion" ])
      expect(LeadFollowup.across_firms.find(first_id).comment).to eq("First discussion")
    end

    it "copies NCD onto the lead when a datetime is sent" do
      when_at = 2.days.from_now.change(usec: 0)

      post "/api/v1/leads/#{lead.id}/followups",
        params: { comment: "Call again", next_action_at: when_at.iso8601 },
        headers: auth(agent), as: :json

      expect(response).to have_http_status(:created)
      expect(lead.reload.next_action_at).to eq(when_at)
      expect(response.parsed_body.dig("lead", "next_action_at")).to be_present
      expect(response.parsed_body.dig("lead", "last_followup_comment")).to eq("Call again")
    end

    it "needs a next call when the followup does not change the status" do
      lead.update!(next_action_at: 3.days.from_now)

      post "/api/v1/leads/#{lead.id}/followups",
        params: { comment: "Just a note" }, headers: auth(agent), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("next_call_required")
      expect(response.parsed_body.dig("error", "message")).to eq("Next call is required.")
      expect(lead.reload.next_action_at).to be_within(1.second).of(3.days.from_now)
      expect(lead.lead_followups.count).to eq(0)
    end

    it "refuses a blank comment" do
      post "/api/v1/leads/#{lead.id}/followups",
        params: { comment: "  " }, headers: auth(agent), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("comment_required")
      expect(lead.lead_followups.count).to eq(0)
    end

    it "changes status in the same transaction" do
      post "/api/v1/leads/#{lead.id}/followups",
        params: { comment: "Hot now", status: hot_status.code, next_action_at: 2.days.from_now.iso8601 },
        headers: auth(agent), as: :json

      expect(response).to have_http_status(:created)
      expect(lead.reload.lead_status).to eq(hot_status)
      expect(lead.lead_followups.count).to eq(1)
    end

    it "rolls back the followup when dead is missing a reason" do
      post "/api/v1/leads/#{lead.id}/followups",
        params: { comment: "Gone", status: dead_status.code },
        headers: auth(agent), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("reason_required")
      expect(lead.reload.lead_status).to eq(new_status)
      expect(lead.lead_followups.count).to eq(0)
    end

    it "sets booked_at from the application date and does not create a booking" do
      lead.update!(next_action_at: 1.day.from_now)

      post "/api/v1/leads/#{lead.id}/followups",
        params: {
          comment: "Token received", status: booked_status.code, booked_on: "2026-09-20"
        },
        headers: auth(agent), as: :json

      expect(response).to have_http_status(:created)
      lead.reload
      expect(lead.lead_status).to eq(booked_status)
      expect(lead.booked_at).to eq(Time.find_zone("Asia/Kolkata").parse("2026-09-20").beginning_of_day)
      expect(lead.next_action_at).to be_nil
      expect(Booking.across_firms.where(lead_id: lead.id).count).to eq(0)
    end

    it "needs an application date to mark booked" do
      post "/api/v1/leads/#{lead.id}/followups",
        params: { comment: "Booked", status: booked_status.code },
        headers: auth(agent), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("application_date_required")
      expect(lead.reload.lead_status).to eq(new_status)
    end

    it "moves a new lead to Followup" do
      post "/api/v1/leads/#{lead.id}/followups",
        params: { comment: "Spoke", status: followup_status.code, next_action_at: 2.days.from_now.iso8601 },
        headers: auth(agent), as: :json

      expect(response).to have_http_status(:created)
      expect(lead.reload.lead_status).to eq(followup_status)
    end

    it "refuses to send the lead back to New" do
      lead.update!(lead_status: hot_status)

      post "/api/v1/leads/#{lead.id}/followups",
        params: { comment: "Reset", status: "new", next_action_at: 2.days.from_now.iso8601 },
        headers: auth(agent), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("new_not_allowed")
      expect(response.parsed_body.dig("error", "message")).to eq("A lead can't go back to New.")
      expect(lead.reload.lead_status).to eq(hot_status)
      expect(lead.lead_followups.count).to eq(0)
    end

    it "refuses a next call in the past, with a short grace for clock drift" do
      post "/api/v1/leads/#{lead.id}/followups",
        params: { comment: "Late", next_action_at: 5.minutes.ago.iso8601 },
        headers: auth(agent), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("next_call_in_past")
      expect(lead.lead_followups.count).to eq(0)

      post "/api/v1/leads/#{lead.id}/followups",
        params: { comment: "Just now", next_action_at: 90.seconds.ago.iso8601 },
        headers: auth(agent), as: :json

      expect(response).to have_http_status(:created)
    end

    it "refuses Visit Planned without a visit, a past visit, or a reminder after the visit" do
      headers = auth(agent)
      reminder = 2.days.from_now.change(usec: 0)

      post "/api/v1/leads/#{lead.id}/followups",
        params: { comment: "Plan", status: visit_status.code, next_action_at: reminder.iso8601 },
        headers:, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("visit_at_required")
      expect(lead.reload.lead_status).to eq(new_status)

      post "/api/v1/leads/#{lead.id}/followups",
        params: {
          comment: "Plan", status: visit_status.code, next_action_at: reminder.iso8601,
          visit_at: 1.hour.ago.iso8601
        }, headers:, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("visit_in_past")

      post "/api/v1/leads/#{lead.id}/followups",
        params: {
          comment: "Plan", status: visit_status.code, next_action_at: 3.days.from_now.iso8601,
          visit_at: reminder.iso8601
        }, headers:, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("reminder_after_visit")
      expect(lead.reload.visit_planned_at).to be_nil
    end

    it "saves Booked and Dead with no next call" do
      headers = auth(agent)

      post "/api/v1/leads/#{lead.id}/followups",
        params: { comment: "Gone", status: dead_status.code, reason: "Not buying" },
        headers:, as: :json

      expect(response).to have_http_status(:created)
      expect(lead.reload.lead_status).to eq(dead_status)
      expect(lead.next_action_at).to be_nil

      other = create(:lead, firm:, lead_status: new_status, assigned_user: agent)
      post "/api/v1/leads/#{other.id}/followups",
        params: { comment: "Token", status: booked_status.code, booked_on: "2026-09-20" },
        headers:, as: :json

      expect(response).to have_http_status(:created)
      expect(other.reload.lead_status).to eq(booked_status)
      expect(other.next_action_at).to be_nil
    end

    it "keeps a due visit overdue after it is logged, until the lead leaves Visit Planned" do
      headers = auth(agent)
      visit_at = 2.hours.from_now.change(usec: 0)
      post "/api/v1/leads/#{lead.id}/followups",
        params: {
          comment: "Saturday visit", status: visit_status.code,
          next_action_at: 1.hour.from_now.iso8601, visit_at: visit_at.iso8601
        }, headers:, as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("lead", "visit_due")).to be(false)
      expect(lead.reload.visit_planned_at).to eq(visit_at)

      travel 3.hours do
        headers = auth(agent)
        get "/api/v1/leads", params: { missed_followup: true }, headers: auth(manager)
        row = response.parsed_body["leads"].find { |item| item["id"] == lead.id }
        expect(row["visit_due"]).to be(true)
        expect(row["overdue"]).to be(true)

        post "/api/v1/leads/#{lead.id}/visits",
          params: { visited_on: Time.zone.today.iso8601, notes: "Walked the site" },
          headers:, as: :json
        expect(response).to have_http_status(:created)
        expect(lead.reload.lead_status).to eq(visit_status)
        expect(lead.visit_planned_at).to eq(visit_at)

        get "/api/v1/leads", params: { missed_followup: true }, headers: auth(manager)
        expect(response.parsed_body["leads"].map { |item| item["id"] }).to include(lead.id)

        post "/api/v1/leads/#{lead.id}/followups",
          params: {
            comment: "After the visit", status: followup_status.code,
            next_action_at: 2.days.from_now.iso8601
          }, headers:, as: :json

        expect(response).to have_http_status(:created)
        expect(lead.reload.lead_status).to eq(followup_status)
        expect(lead.visit_planned_at).to be_nil
        expect(response.parsed_body.dig("lead", "visit_due")).to be(false)

        get "/api/v1/leads", params: { missed_followup: true }, headers: auth(manager)
        expect(response.parsed_body["leads"].map { |item| item["id"] }).not_to include(lead.id)
      end
    end

    it "returns 404 for a lead the agent cannot see" do
      other = create(:lead, firm:, lead_status: new_status, assigned_user: manager)

      post "/api/v1/leads/#{other.id}/followups",
        params: { comment: "sneaky" }, headers: auth(agent), as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /leads/:id/followups" do
    it "returns newest first" do
      headers = auth(agent)
      create(:lead_followup, firm:, lead:, comment: "Older", created_at: 2.days.ago)
      create(:lead_followup, firm:, lead:, comment: "Newer", created_at: 1.hour.ago)

      get "/api/v1/leads/#{lead.id}/followups", headers: headers

      expect(response.parsed_body["followups"].map { |f| f["comment"] }).to eq([ "Newer", "Older" ])
    end
  end
end
