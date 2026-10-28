# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 list filters" do
  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:user) { create(:user, :super_admin, firm:) }
  let!(:new_status) { create(:lead_status, :new_lead) }

  def headers
    post "/api/v1/auth/otp", params: { mobile: user.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify", params: { request_id:, code: deliverer.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
  end

  def expect_invalid(path, params, message)
    get path, params:, headers: headers

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("invalid")
    expect(response.parsed_body.dig("error", "message")).to eq(message)
  end

  it "rejects a lead budget, date, id, enum, boolean, page, or per_page that cannot be read" do
    expect_invalid("/api/v1/leads", { budget_min: "nope" }, "Budget must be a whole number of rupees, 0 or more.")
    expect_invalid("/api/v1/leads", { ncd_from: "tomorrow" }, Reports::Window::INVALID)
    expect_invalid("/api/v1/leads", { property_type_id: "nope" }, "property_type_id must be an id.")
    expect_invalid("/api/v1/leads", { sort: "nope" },
      "sort must be ncd, worklist, recent, updated, booked, or visited.")
    expect_invalid("/api/v1/leads", { side: "both" }, "side must be sale or rent.")
    expect_invalid("/api/v1/leads", { visited: "maybe" }, "visited must be true or false.")
    expect_invalid("/api/v1/leads", { page: "abc" }, "Page must be a whole number, 0 or more.")
    expect_invalid("/api/v1/leads", { per_page: "abc" }, "per_page must be a whole number, 0 or more.")
  end

  it "reads a budget written with Indian commas" do
    inside = create(:lead, firm:, lead_status: new_status, budget_max: 100_000)
    create(:lead, firm:, lead_status: new_status, budget_max: 50_000)

    get "/api/v1/leads", params: { budget_min: "1,00,000" }, headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["leads"].map { |row| row["id"] }).to eq([ inside.id ])
  end

  it "does not bind a raw budget or price string into SQL" do
    expect { Lead.budget_between("nope", nil).load }.not_to raise_error
    expect { Project.budget_between("nope", nil).load }.not_to raise_error
    expect { Property.price_between("nope", nil).load }.not_to raise_error
    expect(Lead.budget_between("1,00,000", nil).to_sql).to include("100000")
  end

  it "rejects a bad prospect, project, property, booking, report, or notification filter" do
    expect_invalid("/api/v1/prospects", { status: "bogus" },
      "status must be new, following, interested, or not_interested.")
    expect_invalid("/api/v1/projects", { budget_min: "nope" }, "Budget must be a whole number of rupees, 0 or more.")
    expect_invalid("/api/v1/projects", { brokerage_min: "nope" }, "Brokerage must be a number, 0 or more.")
    expect_invalid("/api/v1/properties", { price_min: "nope" }, "Price must be a whole number of rupees, 0 or more.")
    expect_invalid("/api/v1/properties", { carpet_min: "nope" }, "Area must be a whole number, 0 or more.")
    expect_invalid("/api/v1/bookings", { booked_from: "nope" }, Reports::Window::INVALID)
    expect_invalid("/api/v1/bookings", { status: "nope" }, "status must be live or cancelled.")
    expect_invalid("/api/v1/reports/source_status", { property_type_id: "nope" }, "property_type_id must be an id.")
    expect_invalid("/api/v1/reports/source_status", { export: "pdf" }, "export must be csv.")
    expect_invalid("/api/v1/notifications", { page: "abc" }, "Page must be a whole number, 0 or more.")
  end

  it "treats match search text as text" do
    lead = create(:lead, firm:, lead_status: new_status)

    post "/api/v1/leads/#{lead.id}/matches", params: { q: "nope" }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
  end

  it "still opens page 1 for page 0" do
    get "/api/v1/leads", params: { page: 0 }, headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("meta", "page")).to eq(1)
  end
end
