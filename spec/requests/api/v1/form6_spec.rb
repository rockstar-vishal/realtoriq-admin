# frozen_string_literal: true

require "rails_helper"
require "zip"

RSpec.describe "API v1 Form 6" do
  let(:plan) { create(:plan) }
  let(:city) { create(:city, name: "Mumbai", state: "Maharashtra") }
  let(:firm) do
    create(:firm, status: :active, name: "Aarav Realty", legal_name: "Aarav Realty Private Limited",
      city:, rera_number: "A51900012345")
  end
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:manager) { create(:user, :manager, firm:) }
  let!(:agent) { create(:user, firm:, role: :agent) }

  def auth(as: manager)
    post "/api/v1/auth/otp", params: { mobile: as.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify", params: { request_id:, code: deliverer.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
  end

  describe "who may open it" do
    it "refuses an agent before it cares which state the firm is in" do
      headers = auth(as: agent)

      get "/api/v1/form6/settings", headers: headers
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("forbidden_role")

      get "/api/v1/form6/preview", params: { period: "2026-04" }, headers: headers
      expect(response.parsed_body.dig("error", "code")).to eq("forbidden_role")
    end

    it "lets a super admin read settings" do
      admin = create(:user, :super_admin, firm:)

      get "/api/v1/form6/settings", headers: auth(as: admin)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["available"]).to be(true)
    end

    it "answers settings when the firm is not in Maharashtra and refuses the rest" do
      other = create(:firm, status: :active, city: nil)
      create(:subscription, firm: other, plan:)
      user = create(:user, :manager, firm: other)
      headers = auth(as: user)

      get "/api/v1/form6/settings", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["available"]).to be(false)
      expect(response.parsed_body["periods"]).not_to be_empty

      patch "/api/v1/form6/settings", params: { signatory_name: "A" }, headers: headers, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("form6_unavailable")

      get "/api/v1/form6/preview", params: { period: "2026-04" }, headers: headers
      expect(response.parsed_body.dig("error", "code")).to eq("form6_unavailable")

      get "/api/v1/form6/download", params: { period: "2026-04" }, headers: headers
      expect(response.parsed_body.dig("error", "code")).to eq("form6_unavailable")
      expect(other.reload.form6).to eq({})
    end
  end

  describe "settings" do
    it "returns the completed halves and the firm's MahaRERA identity" do
      travel_to Time.zone.local(2026, 10, 24, 12, 0, 0) do
        get "/api/v1/form6/settings", headers: auth
      end

      body = response.parsed_body
      expect(body["available"]).to be(true)
      expect(body["firm_rera_number"]).to eq("A51900012345")
      expect(body["firm_legal_name"]).to eq("Aarav Realty Private Limited")
      expect(body["registered_name"]).to be_nil
      expect(body["designated_project_ids"]).to eq([])
      expect(body["turnover_20l_or_more"]).to be(false)
      expect(body["periods"].first).to include("id" => "2026-04", "from" => "2026-04-01", "to" => "2026-09-30",
        "due_on" => "2026-10-20")
      expect(body["periods"].size).to eq(6)
    end

    it "checks types and drops unknown keys" do
      headers = auth
      project = create(:project, firm:)
      foreign = create(:project, firm: create(:firm))

      patch "/api/v1/form6/settings", params: { designated_project_ids: [ "not-a-uuid" ] },
        headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("invalid")

      patch "/api/v1/form6/settings", params: { designated_project_ids: [ foreign.id ] },
        headers: headers, as: :json
      expect(response.parsed_body.dig("error", "details", "designated_project_ids")).to be_present

      patch "/api/v1/form6/settings", params: {
        registered_name: "A" * 161,
        principal_officer: { mobile: "12345", appointed_on: "yesterday", email: "not-an-email" },
        turnover_20l_or_more: "yes"
      }, headers: headers, as: :json
      expect(response.parsed_body.dig("error", "details").keys).to include(
        "registered_name", "principal_officer.mobile", "principal_officer.appointed_on",
        "principal_officer.email", "turnover_20l_or_more"
      )

      patch "/api/v1/form6/settings", params: {
        registered_name: "KGen Agents",
        signatory_name: "Aarav Sethi",
        seal: "ignored",
        designated_project_ids: [ project.id ],
        principal_officer: { name: "Priya Shah", nickname: "PS", mobile: "98765 43210" }
      }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["registered_name"]).to eq("KGen Agents")
      expect(response.parsed_body["designated_project_ids"]).to eq([ project.id ])
      expect(response.parsed_body.dig("principal_officer", "name")).to eq("Priya Shah")
      expect(response.parsed_body.dig("principal_officer", "mobile")).to eq("+919876543210")
      stored = firm.reload.form6
      expect(stored.keys).not_to include("seal")
      expect(stored.dig("principal_officer").keys).to match_array(%w[name mobile])

      patch "/api/v1/form6/settings", params: { signatory_designation: "Partner" }, headers: headers, as: :json
      expect(response.parsed_body["registered_name"]).to eq("KGen Agents")
      expect(response.parsed_body["signatory_designation"]).to eq("Partner")
      expect(firm.reload.form6["signatory_name"]).to eq("Aarav Sethi")
    end

    it "accepts a LaunchIQ catalog project and refuses another firm's project" do
      catalog = Current.set(firm: nil, firm_scope_bypassed: true) do
        create(:project, :catalog, firm: nil, name: "Launch Palm", rera_number: "P51700011111",
          status: "archived")
      end
      foreign = create(:project, firm: create(:firm), name: "Other Firm Tower", rera_number: "P51800099999")
      headers = auth

      patch "/api/v1/form6/settings", params: { designated_project_ids: [ foreign.id ] },
        headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "details", "designated_project_ids")).to be_present

      patch "/api/v1/form6/settings", params: { designated_project_ids: [ catalog.id ] },
        headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["designated_project_ids"]).to eq([ catalog.id ])

      travel_to Time.zone.local(2026, 10, 24, 12, 0, 0) do
        get "/api/v1/form6/download", params: { period: "2026-04" }, headers: headers
      end
      xml = nil
      Zip::File.open_buffer(response.body) do |zip|
        xml = zip.read("word/document.xml").force_encoding(Encoding::UTF_8)
      end
      expect(xml).to include("Launch Palm")
      expect(xml).to include("P51700011111")
      expect(xml).not_to include("Other Firm Tower")
    end
  end

  describe "preview and download" do
    let(:headers) { auth }
    let(:no_rera) { create(:project, firm:, name: "No Rera", rera_number: nil) }
    let(:has_rera) { create(:project, firm:, name: "Has Rera", rera_number: "P51800000001") }
    let(:tower) { create(:project, firm:, name: "Tower & <View>", rera_number: nil) }
    let(:typology) { create(:typology, name: "2 BHK") }
    let(:configuration) { create(:project_typology, project: has_rera, typology:, label: "Ultima") }

    before do
      firm.update!(form6: {
        "designated_project_ids" => [ no_rera.id, has_rera.id ],
        "turnover_20l_or_more" => true
      })
      create(:booking, firm:, project: tower, unit_no: "A-1", customer_name: "Rhea Kapoor",
        booked_on: Date.new(2026, 4, 2))
      create(:booking, firm:, project: tower, unit_no: "A-2", customer_name: "Meera Shah",
        booked_on: Date.new(2026, 4, 10))
      create(:booking, firm:, project: has_rera, project_typology: configuration, unit_no: "B-1",
        customer_name: "Other", booked_on: Date.new(2026, 5, 1))
      create(:booking, :cancelled, firm:, project: tower, unit_no: "A-3", booked_on: Date.new(2026, 6, 1))
      create(:booking, firm:, project: nil, unit_no: nil, customer_name: "No Project",
        booked_on: Date.new(2026, 6, 2))
      create(:booking, :cancelled, firm:, project: nil, unit_no: nil, booked_on: Date.new(2026, 6, 3))
      create(:booking, firm:, project: tower, unit_no: "A-4", booked_on: Date.new(2026, 10, 2))
    end

    it "counts the half-year and names what the form will leave blank" do
      travel_to Time.zone.local(2026, 10, 24, 12, 0, 0) do
        get "/api/v1/form6/preview", params: { period: "2026-04" }, headers: headers
      end

      body = response.parsed_body
      expect(response).to have_http_status(:ok)
      expect(body.dig("period", "id")).to eq("2026-04")
      expect(body["bookings_count"]).to eq(3)
      expect(body["left_out"]).to eq("cancelled" => 2, "without_project" => 1)
      expect(body["designated_projects_count"]).to eq(2)
      expect(body.dig("gaps", "projects_without_rera").map { |row| row["name"] }).to eq([ "No Rera", "Tower & <View>" ])
      expect(body.dig("gaps", "bookings_without_configuration").map { |row| row["customer_name"] }).to eq([
        "Rhea Kapoor", "Meera Shah"
      ])
      expect(body.dig("gaps", "missing_settings")).to eq(
        %w[competency_certificate_no signatory_name signatory_designation] +
        %w[name appointed_on mobile email address].map { |field| "principal_officer.#{field}" } +
        %w[name appointed_on mobile email address].map { |field| "designated_director.#{field}" }
      )
      expect(body["filename"]).to eq("Form6_Aarav-Realty_Apr-Sep-2026.docx")
    end

    it "puts a blank firm registration number first among the blanks" do
      firm.update!(rera_number: nil, form6: { "turnover_20l_or_more" => true, "signatory_name" => "Aarav Sethi" })

      travel_to Time.zone.local(2026, 10, 24, 12, 0, 0) do
        get "/api/v1/form6/preview", params: { period: "2026-04" }, headers: headers
      end

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("gaps", "missing_settings")).to eq(
        %w[firm_rera_number competency_certificate_no signatory_designation] +
        %w[name appointed_on mobile email address].map { |field| "principal_officer.#{field}" } +
        %w[name appointed_on mobile email address].map { |field| "designated_director.#{field}" }
      )
    end

    it "downloads the same file" do
      travel_to Time.zone.local(2026, 10, 24, 12, 0, 0) do
        get "/api/v1/form6/download", params: { period: "2026-04" }, headers: headers
      end

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq(Form6::Document::CONTENT_TYPE)
      expect(response.headers["Content-Disposition"]).to include("Form6_Aarav-Realty_Apr-Sep-2026.docx")
      xml = +""
      Zip::File.open_buffer(response.body) do |zip|
        xml = zip.read("word/document.xml").force_encoding(Encoding::UTF_8)
      end
      expect(xml).to include("Tower &amp; &lt;View&gt;")
      expect(xml).to include("Date: ")
      expect(xml).to include("24/10/2026")
    end

    it "refuses a half that has not ended" do
      travel_to Time.zone.local(2026, 10, 24, 12, 0, 0) do
        get "/api/v1/form6/preview", params: { period: "2026-10" }, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body.dig("error", "code")).to eq("invalid")

        get "/api/v1/form6/download", params: { period: "2026-05" }, headers: headers
        expect(response.parsed_body.dig("error", "code")).to eq("invalid")
      end
    end
  end
end
