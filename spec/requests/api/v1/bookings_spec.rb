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

      expect { create_booking(headers, unit_no: "B-1105") }.to change { Booking.across_firms.count }.by(1)
    end

    it "requires a unit number when a project is chosen" do
      project = create(:project, firm:)

      create_booking(auth, project_id: project.id, unit_no: nil)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "refuses a second live booking of the same unit on a project" do
      project = create(:project, firm:)
      headers = auth
      create_booking(headers, project_id: project.id, unit_no: "B-1104")
      expect(response).to have_http_status(:created)

      create_booking(headers, project_id: project.id, unit_no: "B-1104", lead_id: create(:lead, firm:).id)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("unit_taken")
    end

    it "frees the unit when the live booking is cancelled" do
      project = create(:project, firm:)
      headers = auth
      create_booking(headers, project_id: project.id, unit_no: "B-1104")
      id = response.parsed_body.dig("booking", "id")

      post "/api/v1/bookings/#{id}/cancel", params: { reason: "Client withdrew" },
        headers: headers, as: :json

      create_booking(headers, project_id: project.id, unit_no: "B-1104", lead_id: create(:lead, firm:).id)

      expect(response).to have_http_status(:created)
    end

    it "copies a catalog project into My Projects on booking" do
      catalog = create(:project, :catalog, firm:, name: "LaunchIQ Heights")
      headers = auth
      create_booking(headers, project_id: catalog.id, unit_no: "A-101")

      expect(response).to have_http_status(:created)
      booked_project_id = response.parsed_body.dig("booking", "project", "id")
      expect(booked_project_id).not_to eq(catalog.id)
      own = Project.across_firms.find(booked_project_id)
      expect(own.source).to eq("own")
      expect(own.name).to eq("LaunchIQ Heights")
    end

    it "asks the client to choose when My Projects already has that catalog name" do
      catalog = create(:project, :catalog, firm:, name: "Shared Name")
      existing = create(:project, firm:, name: "Shared Name")
      headers = auth
      create_booking(headers, project_id: catalog.id, unit_no: "A-101")

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("project_name_clash")
      expect(response.parsed_body.dig("error", "details", "existing_project_id")).to eq(existing.id)

      create_booking(headers, project_id: catalog.id, unit_no: "A-101", use_existing: true)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.dig("booking", "project", "id")).to eq(existing.id)
    end

    it "copies under a new name when the client sends one" do
      catalog = create(:project, :catalog, firm:, name: "Shared Name")
      create(:project, firm:, name: "Shared Name")
      headers = auth
      create_booking(headers, project_id: catalog.id, unit_no: "A-101",
                              new_name: "Shared Name (Marketplace)")

      expect(response).to have_http_status(:created)
      own = Project.across_firms.find(response.parsed_body.dig("booking", "project", "id"))
      expect(own.source).to eq("own")
      expect(own.name).to eq("Shared Name (Marketplace)")
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

    it "reports an unfinished proof as a 422, not a 500" do
      raise_invoice("INV-1", 400_000)
      post "/api/v1/uploads", params: {
        purpose: "collection_proof", filename: "proof.png",
        byte_size: 11, checksum: "XrY7u+Ae7tCTyyK7j1rNww==", content_type: "image/png"
      }, headers: headers, as: :json

      post "/api/v1/bookings/#{booking_id}/collections",
        params: { received_on: "2026-08-18", amount: 1, mode: "cash",
                  proof_signed_id: response.parsed_body["signed_id"] },
        headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("upload_incomplete")
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

    it "cancels a live booking that has a project and no unit_no" do
      project = create(:project, firm:)
      booking = create(:booking, firm:, lead:, project:, unit_no: "TEMP")
      booking.update_columns(unit_no: nil)

      post "/api/v1/bookings/#{booking.id}/cancel",
        params: { reason: "TEst" },
        headers: headers.merge("Accept" => "text/html"),
        as: :json

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/json")
      expect(response.parsed_body.dig("booking", "status")).to eq("cancelled")
    end

    it "returns the JSON envelope, not public/422.html, when cancel raises RecordInvalid" do
      create_booking(headers)
      id = response.parsed_body.dig("booking", "id")
      booking = Booking.across_firms.find(id)
      allow_any_instance_of(Booking).to receive(:cancel!).and_wrap_original do
        booking.errors.add(:unit_no, :blank)
        raise ActiveRecord::RecordInvalid, booking
      end

      post "/api/v1/bookings/#{id}/cancel",
        params: { reason: "TEst" },
        headers: headers.merge("Accept" => "text/html"),
        as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.media_type).to eq("application/json")
      expect(response.parsed_body.dig("error", "code")).to eq("invalid")
      expect(response.body).not_to include("The change you wanted was rejected")
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

    it "finds a booking by project name" do
      headers = auth
      project = create(:project, firm:, name: "Marina Bay")
      create_booking(headers, project_id: project.id)

      get "/api/v1/bookings", params: { q: "Marina" }, headers: headers

      expect(response.parsed_body["bookings"].map { |b| b.dig("project", "name") }).to eq([ "Marina Bay" ])
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

  describe "an update that would strand invoices already raised" do
    it "refuses to drop net income below what has been invoiced" do
      headers = auth
      create_booking(headers, agreement_value: 10_000_000, commission_percent: 4.5,
                              kicker: 0, passback: 0)
      booking_id = response.parsed_body.dig("booking", "id")
      # 4.5% of 1 Cr = 450000, invoiced in full.
      post "/api/v1/bookings/#{booking_id}/invoices",
        params: { number: "INV-STRAND", issued_on: Date.current, amount: 450_000 },
        headers: headers, as: :json
      expect(response).to have_http_status(:created)

      patch "/api/v1/bookings/#{booking_id}",
        params: { agreement_value: 100_000 }, headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("over_invoiced")
      expect(response.parsed_body.dig("error", "details", "shortfall")).to eq(450_000 - 4_500)
    end

    it "leaves the booking untouched when it refuses" do
      headers = auth
      create_booking(headers, agreement_value: 10_000_000, commission_percent: 4.5,
                              kicker: 0, passback: 0)
      booking_id = response.parsed_body.dig("booking", "id")
      post "/api/v1/bookings/#{booking_id}/invoices",
        params: { number: "INV-STRAND-2", issued_on: Date.current, amount: 450_000 },
        headers: headers, as: :json

      patch "/api/v1/bookings/#{booking_id}",
        params: { agreement_value: 100_000, unit_no: "CHANGED" }, headers: headers, as: :json

      get "/api/v1/bookings/#{booking_id}", headers: headers
      expect(response.parsed_body.dig("booking", "agreement_value")).to eq(10_000_000)
      expect(response.parsed_body.dig("booking", "net_income")).to eq(450_000)
      expect(response.parsed_body.dig("booking", "unit_no")).not_to eq("CHANGED")
    end

    it "allows a reduction that still covers what is invoiced" do
      headers = auth
      create_booking(headers, agreement_value: 10_000_000, commission_percent: 4.5,
                              kicker: 0, passback: 0)
      booking_id = response.parsed_body.dig("booking", "id")
      post "/api/v1/bookings/#{booking_id}/invoices",
        params: { number: "INV-OK", issued_on: Date.current, amount: 100_000 },
        headers: headers, as: :json

      # 4.5% of 50 L = 225000, still above the 100000 invoiced.
      patch "/api/v1/bookings/#{booking_id}",
        params: { agreement_value: 5_000_000 }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("booking", "net_income")).to eq(225_000)
    end

    it "still allows any update on a booking with no invoices" do
      headers = auth
      create_booking(headers, agreement_value: 10_000_000, commission_percent: 4.5)
      booking_id = response.parsed_body.dig("booking", "id")

      patch "/api/v1/bookings/#{booking_id}",
        params: { agreement_value: 100_000 }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
    end
  end
end
