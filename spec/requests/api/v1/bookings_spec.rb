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

    it "copies a marketplace project into My Projects on booking" do
      catalog = Current.set(firm: nil, firm_scope_bypassed: true) do
        create(:project, :catalog, firm: nil, name: "Harbour One", external_ref: "PRBEEF01")
      end
      headers = auth
      create_booking(headers, project_id: catalog.id, unit_no: "A-101")

      expect(response).to have_http_status(:created)
      booked_project_id = response.parsed_body.dig("booking", "project", "id")
      expect(booked_project_id).not_to eq(catalog.id)
      own = Project.across_firms.find(booked_project_id)
      expect(own.source).to eq("own")
      expect(own.firm_id).to eq(firm.id)
      expect(own.external_ref).to eq("PRBEEF01")
      expect(catalog.reload.firm_id).to be_nil
    end

    it "copies a marketplace project into My Projects when a booking is edited" do
      catalog = Current.set(firm: nil, firm_scope_bypassed: true) do
        create(:project, :catalog, firm: nil, name: "Harbour Two", external_ref: "PRBEEF02")
      end
      headers = auth
      create_booking(headers, unit_no: nil)
      expect(response).to have_http_status(:created)
      booking_id = response.parsed_body.dig("booking", "id")

      patch "/api/v1/bookings/#{booking_id}",
        params: { project_id: catalog.id, unit_no: "A-202" },
        headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      booked_project_id = response.parsed_body.dig("booking", "project", "id")
      expect(booked_project_id).not_to eq(catalog.id)
      own = Project.across_firms.find(booked_project_id)
      expect(own.source).to eq("own")
      expect(own.firm_id).to eq(firm.id)
      expect(own.external_ref).to eq("PRBEEF02")
      expect(Booking.across_firms.find(booking_id).project_id).to eq(own.id)
      expect(catalog.reload.firm_id).to be_nil
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
      expect(Booking.across_firms.find(booking_id).invoiced_amount).to eq(500_000)
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
      expect(totals["invoiced"]).to eq(500_000)
      expect(totals["collected"]).to eq(200_000)
      expect(totals["outstanding"]).to eq(300_000)
      expect(totals["to_invoice"]).to eq(0)
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

  describe "the list's stages, totals and rows" do
    def staged_booking(**columns)
      booking = create(:booking, firm:, lead:, agreement_value: 10_000_000, commission_percent: 1,
        kicker: 0, passback: 0, customer_mobile: "+919800011122",
        project: columns.delete(:project), unit_no: columns.delete(:unit_no),
        project_typology: columns.delete(:project_typology),
        booked_on: columns.delete(:booked_on) || Date.new(2026, 8, 1),
        registration_done_on: columns.delete(:registration_done_on))
      booking.update_columns(net_income: 100_000, **columns) if columns.any?
      booking
    end

    it "filters by stage and keeps stage counts for the unstaged set" do
      awaiting = staged_booking(invoiced_amount: 40_000, collected_amount: 10_000, unit_no: "A-1")
      staged_booking(unit_no: "A-2")
      staged_booking(invoiced_amount: 100_000, collected_amount: 100_000, unit_no: "A-3")
      cancelled = staged_booking(status: "cancelled", invoiced_amount: 100_000, collected_amount: 100_000,
        unit_no: "A-4", cancellation_reason: "Client withdrew", cancelled_at: Time.current)
      headers = auth

      get "/api/v1/bookings", params: { stage: "awaiting_payment" }, headers: headers

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["bookings"].map { |row| row["id"] }).to eq([ awaiting.id ])
      row = body["bookings"].first
      expect(row["stage"]).to eq("awaiting_payment")
      expect(row["invoiced"]).to eq(40_000)
      expect(row["collected"]).to eq(10_000)
      expect(row["outstanding"]).to eq(30_000)
      expect(row["to_invoice"]).to eq(60_000)
      expect(body["totals"]).to include(
        "agreement_value" => 10_000_000, "net_income" => 100_000,
        "invoiced" => 40_000, "collected" => 10_000, "outstanding" => 30_000, "to_invoice" => 60_000
      )
      expect(body["stage_counts"]).to eq(
        "all" => 3, "to_invoice" => 1, "awaiting_payment" => 1, "paid" => 1, "cancelled" => 1
      )
      expect(cancelled.stage).to eq("cancelled")
    end

    it "returns cancelled rows for status and zeroes their live totals" do
      staged_booking(status: "cancelled", unit_no: "C-1", cancellation_reason: "Client withdrew",
        cancelled_at: Time.current, invoiced_amount: 50_000, collected_amount: 20_000)
      headers = auth

      get "/api/v1/bookings", params: { status: "cancelled" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["bookings"].size).to eq(1)
      expect(response.parsed_body.dig("bookings", 0, "cancellation_reason")).to eq("Client withdrew")
      expect(response.parsed_body["totals"].values).to all(eq(0))
      expect(response.parsed_body.dig("stage_counts", "all")).to eq(0)
      expect(response.parsed_body.dig("stage_counts", "cancelled")).to eq(1)
    end

    it "refuses an unknown stage or registration" do
      headers = auth

      get "/api/v1/bookings", params: { stage: "won" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("invalid")

      get "/api/v1/bookings", params: { registration: "nope" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("invalid")
    end

    it "searches the booking code and the customer phone, and filters registration" do
      done = staged_booking(unit_no: "S-1", registration_done_on: Date.new(2026, 8, 20),
        customer_mobile: "+919811100001")
      staged_booking(unit_no: "S-2", customer_mobile: "+919822200002")
      headers = auth

      get "/api/v1/bookings", params: { q: done.code }, headers: headers
      expect(response.parsed_body["bookings"].map { |row| row["id"] }).to eq([ done.id ])

      get "/api/v1/bookings", params: { q: "9811100001" }, headers: headers
      expect(response.parsed_body["bookings"].map { |row| row["id"] }).to eq([ done.id ])

      get "/api/v1/bookings", params: { q: "98111 00001" }, headers: headers
      expect(response.parsed_body["bookings"].map { |row| row["id"] }).to eq([ done.id ])

      get "/api/v1/bookings", params: { q: "+91 98111-00001" }, headers: headers
      expect(response.parsed_body["bookings"].map { |row| row["id"] }).to eq([ done.id ])

      get "/api/v1/bookings", params: { client_phone: "9811100001" }, headers: headers
      expect(response.parsed_body["bookings"].map { |row| row["id"] }).to eq([ done.id ])

      get "/api/v1/bookings", params: { registration: "done" }, headers: headers
      expect(response.parsed_body["bookings"].map { |row| row["id"] }).to eq([ done.id ])
      expect(response.parsed_body.dig("bookings", 0, "registration_done_on")).to eq("2026-08-20")

      get "/api/v1/bookings", params: { registration: "pending" }, headers: headers
      expect(response.parsed_body["bookings"].size).to eq(1)
      expect(response.parsed_body.dig("bookings", 0, "id")).not_to eq(done.id)
    end

    it "returns the oldest raised invoice that still has a balance of its own" do
      booking = staged_booking(unit_no: "I-1", invoiced_amount: 150, collected_amount: 100)
      create(:invoice, firm:, booking:, amount: 100, issued_on: Date.new(2026, 6, 1), status: "cancelled")
      older = create(:invoice, firm:, booking:, amount: 100, issued_on: Date.new(2026, 7, 1))
      create(:invoice, firm:, booking:, amount: 50, issued_on: Date.new(2026, 8, 1))
      create(:collection, firm:, booking:, invoice: older, amount: 100)
      create(:collection, firm:, booking:, invoice: nil, amount: 50)
      headers = auth

      get "/api/v1/bookings", headers: headers

      row = response.parsed_body["bookings"].find { |item| item["id"] == booking.id }
      expect(row["oldest_due_invoice_on"]).to eq("2026-08-01")
    end

    it "names who recorded the booking on the detail" do
      headers = auth
      create_booking(headers)
      id = response.parsed_body.dig("booking", "id")

      get "/api/v1/bookings/#{id}", headers: headers

      expect(response.parsed_body.dig("booking", "created_by_name")).to eq(manager.name)
    end

    it "does not add a query per row" do
      project = create(:project, firm:, name: "Query Heights")
      typology = create(:typology, name: "3 BHK")
      configuration = create(:project_typology, project:, typology:, label: "West")

      5.times do |n|
        booking = staged_booking(project:, project_typology: configuration, unit_no: "Q-#{n}",
          invoiced_amount: 1_000, collected_amount: 100)
        invoice = create(:invoice, firm:, booking:, amount: 1_000, issued_on: Date.new(2026, 7, 1))
        create(:collection, firm:, booking:, invoice:, amount: 100)
      end
      headers = auth
      get "/api/v1/bookings", params: { per_page: 50 }, headers: headers

      small = nil
      large = nil
      ActiveRecord::Base.uncached do
        small = select_count { get "/api/v1/bookings", params: { per_page: 50 }, headers: headers }
        20.times do |n|
          booking = staged_booking(project:, project_typology: configuration, unit_no: "R-#{n}",
            invoiced_amount: 1_000, collected_amount: 100)
          invoice = create(:invoice, firm:, booking:, amount: 1_000, issued_on: Date.new(2026, 7, 1))
          create(:collection, firm:, booking:, invoice:, amount: 100)
        end
        large = select_count { get "/api/v1/bookings", params: { per_page: 50 }, headers: headers }
      end

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["bookings"].size).to eq(25)
      expect(response.parsed_body["bookings"]).to all(include("configuration" => hash_including("label" => "3 BHK West")))
      expect(large).to eq(small)
    end
  end

  describe "configuration on create and update" do
    it "stores a configuration of the firm's project" do
      project = create(:project, firm:)
      typology = create(:typology, name: "2 BHK")
      row = create(:project_typology, project:, typology:, label: "Ultima")
      headers = auth

      create_booking(headers, project_id: project.id, unit_no: "U-1", project_typology_id: row.id)

      expect(response).to have_http_status(:created)
      configuration = response.parsed_body.dig("booking", "configuration")
      expect(configuration).to eq(
        "id" => row.id, "label" => "2 BHK Ultima", "category" => "residential", "typology_id" => typology.id
      )
      expect(response.parsed_body.dig("booking", "category")).to eq("residential")
    end

    it "refuses a configuration from another project" do
      project = create(:project, firm:)
      other = create(:project_typology, project: create(:project, firm:))
      headers = auth

      create_booking(headers, project_id: project.id, unit_no: "U-2", project_typology_id: other.id)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("invalid")
      expect(Booking.across_firms.where(lead:).count).to eq(0)
    end

    it "maps a marketplace configuration onto the firm's copy" do
      typology = create(:typology, name: "2 BHK")
      catalog = Current.set(firm: nil, firm_scope_bypassed: true) do
        project = create(:project, :catalog, firm: nil, name: "Harbour Config", external_ref: "PRCFG01")
        create(:project_typology, project:, typology:, label: "Ultima")
        project
      end
      source = catalog.project_typologies.first
      headers = auth

      create_booking(headers, project_id: catalog.id, unit_no: "U-3", project_typology_id: source.id)

      expect(response).to have_http_status(:created)
      configuration = response.parsed_body.dig("booking", "configuration")
      own_id = response.parsed_body.dig("booking", "project", "id")
      expect(configuration["id"]).not_to eq(source.id)
      expect(configuration["label"]).to eq("2 BHK Ultima")
      expect(ProjectTypology.find(configuration["id"]).project_id).to eq(own_id)
    end

    it "saves the snapshot when the firm's copy has no such configuration" do
      typology = create(:typology, name: "2 BHK")
      catalog = Current.set(firm: nil, firm_scope_bypassed: true) do
        project = create(:project, :catalog, firm: nil, name: "Harbour Missing", external_ref: "PRMISS01")
        create(:project_typology, project:, typology:, label: "Ultima")
        project
      end
      own = create(:project, firm:, name: "Already Copied", external_ref: "PRMISS01")
      source = catalog.project_typologies.first
      headers = auth

      create_booking(headers, project_id: catalog.id, unit_no: "U-4", project_typology_id: source.id)

      expect(response).to have_http_status(:created)
      configuration = response.parsed_body.dig("booking", "configuration")
      expect(response.parsed_body.dig("booking", "project", "id")).to eq(own.id)
      expect(configuration).to eq(
        "id" => nil, "label" => "2 BHK Ultima", "category" => "residential", "typology_id" => typology.id
      )
      stored = Booking.across_firms.find(response.parsed_body.dig("booking", "id"))
      expect(stored.project_typology_id).to be_nil
      expect(stored.configuration_label).to eq("Ultima")
    end

    it "keeps the snapshot when an update omits it, and clears it when null is sent" do
      project = create(:project, firm:)
      typology = create(:typology, name: "Shop", category: "commercial")
      row = create(:project_typology, project:, typology:, label: "Front")
      headers = auth
      create_booking(headers, project_id: project.id, unit_no: "U-5", project_typology_id: row.id)
      id = response.parsed_body.dig("booking", "id")

      patch "/api/v1/bookings/#{id}", params: { agreement_value: 10_000_000 }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("booking", "configuration", "label")).to eq("Shop Front")
      expect(Booking.across_firms.find(id).typology_id).to eq(typology.id)

      patch "/api/v1/bookings/#{id}", params: { project_typology_id: nil }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("booking", "configuration")).to be_nil
      stored = Booking.across_firms.find(id)
      expect(stored.project_typology_id).to be_nil
      expect(stored.typology_id).to be_nil
      expect(stored.configuration_label).to be_nil
    end

    it "keeps the booked configuration when the project is saved in the configuration editor" do
      owner = create(:user, :super_admin, firm:)
      project = create(:project, firm:, locality: create(:locality), lat: 19.07, lng: 73.02,
        possession_on: Date.new(2027, 12, 1))
      typology = create(:typology, name: "2 BHK")
      row = create(:project_typology, project:, typology:, label: "Ultima", starting_price: 14_200_000,
        starting_carpet_sqft: 720)
      headers = auth
      create_booking(headers, project_id: project.id, unit_no: "U-9", project_typology_id: row.id,
        booked_on: "2026-05-01")
      booking_id = response.parsed_body.dig("booking", "id")

      patch "/api/v1/projects/#{project.id}", params: {
        typologies: [
          { typology_id: typology.id, starting_price: 15_000_000, starting_carpet_sqft: 720, label: "Ultima" }
        ]
      }, headers: auth(as: owner), as: :json

      expect(response).to have_http_status(:ok), response.body
      new_id = response.parsed_body.dig("project", "typologies", 0, "id")
      expect(new_id).not_to eq(row.id)

      get "/api/v1/bookings/#{booking_id}", headers: headers
      configuration = response.parsed_body.dig("booking", "configuration")
      expect(configuration).to eq(
        "id" => new_id, "label" => "2 BHK Ultima", "category" => "residential", "typology_id" => typology.id
      )
      stored = Booking.across_firms.find(booking_id)
      expect(stored.project_typology_id).to be_nil
      expect(stored.configuration_label).to eq("Ultima")

      Current.firm = firm
      report = Form6::Report.new(firm:, period: Form6::Period.parse("2026-04"))
      form_row = report.table_b_rows.find { |booking| booking.id == booking_id }
      expect(Form6::Classification.unit_type(form_row.typology)).to eq("Apartment")
      expect(Form6::Classification.category_label(form_row.typology)).to eq("Residential")
      expect(report.bookings_without_configuration.map { |item| item[:id] }).not_to include(booking_id)
    end
  end

  describe "mark_lead_booked" do
    it "moves the lead to Booked with the same activity a manual change writes" do
      following = create(:lead_status, name: "Following")
      create(:lead_status, :booked, name: "Booked")
      booked_lead = create(:lead, firm:, lead_status: following, name: "Booked Buyer")
      headers = auth

      booked_on = Date.current - 3
      post "/api/v1/bookings", params: {
        lead_id: booked_lead.id, booked_on: booked_on.iso8601, agreement_value: 1_000_000,
        commission_percent: 1, mark_lead_booked: true
      }, headers: headers, as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body).not_to have_key("lead_status_unchanged")
      expect(booked_lead.reload.lead_status.name).to eq("Booked")
      expect(booked_lead.booked_at).to eq(booked_on.in_time_zone(Lead::NCD_ZONE).beginning_of_day)
      activity = booked_lead.lead_activities.find_by(kind: "status_change")
      expect(activity.body).to eq("Following → Booked")
      expect(activity.user_id).to eq(manager.id)
    end

    it "saves the booking and says so when the firm has no booked status" do
      LeadStatus.where(is_booked: true).update_all(is_booked: false)
      headers = auth
      status_id = lead.lead_status_id

      create_booking(headers, mark_lead_booked: true)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["lead_status_unchanged"]).to be(true)
      expect(lead.reload.lead_status_id).to eq(status_id)
      expect(lead.lead_activities.where(kind: "status_change")).to be_none
    end

    it "leaves the lead alone when the flag is false" do
      create(:lead_status, :booked, name: "Booked")
      headers = auth
      status_id = lead.lead_status_id

      create_booking(headers, mark_lead_booked: false)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body).not_to have_key("lead_status_unchanged")
      expect(lead.reload.lead_status_id).to eq(status_id)
    end

    it "rolls the booking back when the lead cannot move" do
      following = create(:lead_status, name: "Following")
      dead = create(:lead_status, :dead)
      create(:lead_status, :booked, name: "Booked")
      mobile = "+919811122233"
      # The dead lead has to exist first. A second open lead on the same
      # mobile is refused; a dead one is not an open lead, so the live one
      # can follow it. Reviving the dead one then hits that live lead.
      dead_lead = create(:lead, firm:, mobile:, lead_status: dead, name: "Dead", dead_reason: "Bought elsewhere")
      create(:lead, firm:, mobile:, lead_status: following, name: "Open")
      headers = auth

      post "/api/v1/bookings", params: {
        lead_id: dead_lead.id, booked_on: "2026-08-01", agreement_value: 1_000_000,
        commission_percent: 1, mark_lead_booked: true
      }, headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("duplicate_lead")
      expect(Booking.across_firms.where(lead_id: dead_lead.id)).to be_none
      expect(dead_lead.reload.lead_status_id).to eq(dead.id)
    end
  end
end

def select_count
  queries = []
  callback = lambda do |_name, _start, _finish, _id, payload|
    sql = payload[:sql].to_s
    next if payload[:name] == "SCHEMA"

    queries << sql if sql.start_with?("SELECT")
  end
  ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
  queries.size
end
