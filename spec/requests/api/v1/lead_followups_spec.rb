# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 lead followups" do
  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:manager) { create(:user, :manager, firm:) }
  let!(:agent) { create(:user, firm:, role: :agent) }
  let!(:new_status) { create(:lead_status, :new_lead) }
  let!(:hot_status) { create(:lead_status, :hot) }
  let!(:dead_status) { create(:lead_status, :dead) }
  let!(:booked_status) { create(:lead_status, :booked) }
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
        params: { comment: "First discussion" }, headers:, as: :json
      first_id = response.parsed_body.dig("followup", "id")

      post "/api/v1/leads/#{lead.id}/followups",
        params: { comment: "Second discussion" }, headers:, as: :json

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

    it "does not clear NCD when the followup has no datetime" do
      lead.update!(next_action_at: 3.days.from_now)

      post "/api/v1/leads/#{lead.id}/followups",
        params: { comment: "Just a note" }, headers: auth(agent), as: :json

      expect(lead.reload.next_action_at).to be_within(1.second).of(3.days.from_now)
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
        params: { comment: "Hot now", status: hot_status.code },
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
