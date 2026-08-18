# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 bookings" do
  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:manager) { create(:user, :manager, firm:) }
  let!(:agent) { create(:user, firm:, role: :agent) }
  let!(:lead) { create(:lead, firm:, assigned_user: agent, name: "Rhea Kapoor") }

  def auth(as: manager)
    post "/api/v1/auth/otp", params: { mobile: as.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify", params: { request_id:, code: deliverer.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
  end

  def create_booking(headers, overrides = {})
    post "/api/v1/bookings", params: {
      lead_id: lead.id, booked_on: "2026-08-01", agreement_value: 15_600_000,
      commission_percent: 4.5, kicker: 50_000, passback: 66_000,
      builder_ref_no: "AV/BK/1184", unit_no: "B-1104"
    }.merge(overrides), headers: headers, as: :json
  end

  describe "who may touch bookings" do
    it "refuses an agent on every action" do
      headers = auth(as: agent)

      get "/api/v1/bookings", headers: headers
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("forbidden_role")

      create_booking(headers)
      expect(response).to have_http_status(:forbidden)
    end

    it "lets a manager in" do
      get "/api/v1/bookings", headers: auth

      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /bookings" do
    it "creates one and returns the design's revenue breakdown" do
      create_booking(auth)

      revenue = response.parsed_body.dig("booking", "revenue")
      expect(response).to have_http_status(:created)
      expect(revenue["commission_amount"]).to eq(702_000)
      expect(revenue["net_income"]).to eq(686_000)
    end

    it "snapshots the customer from the lead" do
      create_booking(auth)

      expect(response.parsed_body.dig("booking", "customer_name")).to eq("Rhea Kapoor")
    end

    it "keeps the snapshot when the lead is later corrected" do
      create_booking(auth)
      id = response.parsed_body.dig("booking", "id")
      lead.update!(name: "Rhea K. Kapoor")

      get "/api/v1/bookings/#{id}", headers: auth

      expect(response.parsed_body.dig("booking", "customer_name")).to eq("Rhea Kapoor")
    end

    it "refuses a booking with no lead" do
      post "/api/v1/bookings", params: { agreement_value: 1, commission_percent: 1 },
        headers: auth, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("lead_required")
    end

    it "leaves the lead's status alone" do
      original = lead.lead_status_id

      create_booking(auth)

      expect(lead.reload.lead_status_id).to eq(original)
      expect(lead.booked_at).to be_nil
    end

    it "allows a second booking on the same lead" do
      headers = auth
      create_booking(headers)

      expect { create_booking(headers) }.to change { Booking.across_firms.count }.by(1)
    end
  end

  describe "invoices" do
    let(:headers) { auth }
    let(:booking_id) do
      create_booking(headers, agreement_value: 10_000_000, commission_percent: 5,
        kicker: 0, passback: 0)
      response.parsed_body.dig("booking", "id")
    end

    it "raises one up to the net income" do
      post "/api/v1/bookings/#{booking_id}/invoices",
        params: { number: "INV-1", issued_on: "2026-08-04", amount: 500_000 },
        headers: headers, as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("booking", "invoiced")).to eq(500_000)
    end

    it "hard-blocks anything past it, and shows the arithmetic" do
      post "/api/v1/bookings/#{booking_id}/invoices",
        params: { number: "INV-1", issued_on: "2026-08-04", amount: 500_000 },
        headers: headers, as: :json

      post "/api/v1/bookings/#{booking_id}/invoices",
        params: { number: "INV-2", issued_on: "2026-08-05", amount: 1 },
        headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      error = response.parsed_body["error"]
      expect(error["code"]).to eq("over_invoiced")
      expect(error["details"]).to include(
        "net_income" => 500_000, "already_invoiced" => 500_000, "available" => 0
      )
    end

    it "refuses a duplicate number even when there is headroom" do
      post "/api/v1/bookings/#{booking_id}/invoices",
        params: { number: "INV-DUP", issued_on: "2026-08-04", amount: 100_000 },
        headers: headers, as: :json

      post "/api/v1/bookings/#{booking_id}/invoices",
        params: { number: "INV-DUP", issued_on: "2026-08-05", amount: 50_000 },
        headers: headers, as: :json

      expect(response.parsed_body.dig("error", "code")).to eq("duplicate_invoice_number")
    end
  end

  describe "collections" do
    let(:headers) { auth }
    let(:booking_id) do
      create_booking(headers, agreement_value: 10_000_000, commission_percent: 5,
        kicker: 0, passback: 0)
      response.parsed_body.dig("booking", "id")
    end

    def raise_invoice(number, amount)
      post "/api/v1/bookings/#{booking_id}/invoices",
        params: { number:, issued_on: "2026-08-04", amount: },
        headers: headers, as: :json
      response.parsed_body.dig("invoice", "id")
    end

    it "records a payment against an invoice" do
      invoice_id = raise_invoice("INV-1", 400_000)

      post "/api/v1/bookings/#{booking_id}/collections",
        params: { invoice_id:, received_on: "2026-08-18", amount: 150_000,
                  mode: "neft_rtgs", transaction_no: "8842190" },
        headers: headers, as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("booking", "collected")).to eq(150_000)
      expect(response.parsed_body.dig("booking", "outstanding")).to eq(250_000)
    end

    it "records an unlinked payment" do
      raise_invoice("INV-1", 400_000)

      post "/api/v1/bookings/#{booking_id}/collections",
        params: { received_on: "2026-08-18", amount: 100_000, mode: "cash" },
        headers: headers, as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("collection", "invoice")).to be_nil
    end

    it "hard-blocks collecting more than was invoiced" do
      raise_invoice("INV-1", 100_000)

      post "/api/v1/bookings/#{booking_id}/collections",
        params: { received_on: "2026-08-18", amount: 200_000, mode: "upi" },
        headers: headers, as: :json

      expect(response.parsed_body.dig("error", "code")).to eq("over_collected")
    end

    it "hard-blocks a payment past its own invoice, even with headroom elsewhere" do
      # Two invoices totalling 500,000, so 400,000 is within the booking's
      # total — but not within the 300,000 invoice it names. This is the case
      # that catches a payment filed against the wrong invoice.
      invoice_id = raise_invoice("INV-A", 300_000)
      raise_invoice("INV-B", 200_000)

      post "/api/v1/bookings/#{booking_id}/collections",
        params: { invoice_id:, received_on: "2026-08-18", amount: 400_000, mode: "upi" },
        headers: headers, as: :json

      error = response.parsed_body["error"]
      expect(error["code"]).to eq("over_collected_for_invoice")
      expect(error["details"]).to include("invoice_amount" => 300_000, "available" => 300_000)
    end

    it "refuses an invoice belonging to another booking" do
      other = create(:invoice, firm:)

      post "/api/v1/bookings/#{booking_id}/collections",
        params: { invoice_id: other.id, received_on: "2026-08-18", amount: 1, mode: "cash" },
        headers: headers, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "cancelling" do
    let(:headers) { auth }

    it "needs a reason" do
      create_booking(headers)
      id = response.parsed_body.dig("booking", "id")

      post "/api/v1/bookings/#{id}/cancel", params: {}, headers: headers, as: :json

      expect(response.parsed_body.dig("error", "code")).to eq("reason_required")
    end

    it "cancels, keeps the invoices, and leaves the lead alone" do
      create_booking(headers)
      id = response.parsed_body.dig("booking", "id")
      post "/api/v1/bookings/#{id}/invoices",
        params: { number: "INV-1", issued_on: "2026-08-04", amount: 100_000 },
        headers: headers, as: :json
      original_status = lead.reload.lead_status_id

      post "/api/v1/bookings/#{id}/cancel", params: { reason: "Client withdrew" },
        headers: headers, as: :json

      booking = response.parsed_body["booking"]
      expect(booking["status"]).to eq("cancelled")
      expect(booking["invoices"].size).to eq(1)
      expect(lead.reload.lead_status_id).to eq(original_status)
    end

    it "refuses further invoices once cancelled" do
      create_booking(headers)
      id = response.parsed_body.dig("booking", "id")
      post "/api/v1/bookings/#{id}/cancel", params: { reason: "x" }, headers: headers, as: :json

      post "/api/v1/bookings/#{id}/invoices",
        params: { number: "INV-9", issued_on: "2026-08-04", amount: 1 },
        headers: headers, as: :json

      expect(response.parsed_body.dig("error", "code")).to eq("already_cancelled")
    end
  end

  describe "GET /bookings" do
    it "excludes cancelled bookings by default" do
      headers = auth
      create_booking(headers)
      create_booking(headers)
      id = response.parsed_body.dig("booking", "id")
      post "/api/v1/bookings/#{id}/cancel", params: { reason: "x" }, headers: headers, as: :json

      get "/api/v1/bookings", headers: headers

      expect(response.parsed_body.dig("meta", "total_count")).to eq(1)
    end

    it "does not inflate totals when a booking has invoices and collections" do
      # Regression: the list eager-loaded invoices and collections, and summing
      # over that join counted a booking once per associated row — reporting
      # double the firm's revenue.
      headers = auth
      create_booking(headers, agreement_value: 10_000_000, commission_percent: 5,
        kicker: 0, passback: 0)
      id = response.parsed_body.dig("booking", "id")
      post "/api/v1/bookings/#{id}/invoices",
        params: { number: "INV-1", issued_on: "2026-08-04", amount: 500_000 },
        headers: headers, as: :json
      2.times do |n|
        post "/api/v1/bookings/#{id}/collections",
          params: { received_on: "2026-08-1#{n}", amount: 100_000, mode: "cash" },
          headers: headers, as: :json
      end

      get "/api/v1/bookings", headers: headers

      totals = response.parsed_body["totals"]
      expect(totals["agreement_value"]).to eq(10_000_000)
      expect(totals["net_income"]).to eq(500_000)
    end

    it "returns 404 for another firm's booking" do
      other = create(:booking, firm: create(:firm))

      get "/api/v1/bookings/#{other.id}", headers: auth

      expect(response).to have_http_status(:not_found)
    end
  end
end
