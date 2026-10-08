# frozen_string_literal: true

require "rails_helper"
require "csv"

RSpec.describe "API v1 prospects" do
  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:manager) { create(:user, :manager, firm:) }
  let!(:agent) { create(:user, firm:, role: :agent) }
  let!(:other_agent) { create(:user, firm:, role: :agent) }
  let!(:lead_status) { create(:lead_status, :new_lead) }
  let!(:property_type) { create(:property_type) }
  let!(:typology) { create(:typology) }
  let!(:locality) { create(:locality) }

  def auth(user)
    post "/api/v1/auth/otp", params: { mobile: user.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify", params: { request_id:, code: deliverer.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body["access_token"]}" }
  end

  def upload(content, name: "prospects.csv")
    file = Tempfile.new([ "prospects", File.extname(name) ])
    file.write(content)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "text/csv", original_filename: name)
  end

  def requirements
    {
      mode: "requirements",
      transaction_type: "sale",
      property_type_id: property_type.id,
      budget: 12_000_000,
      typology_ids: [ typology.id ],
      locality_ids: [ locality.id ]
    }
  end

  describe "import" do
    it "imports messy numbers and rejects a bad cell without undoing the good row" do
      csv = CSV.generate do |sheet|
        sheet << [ "Client name", "Client number", "Comment" ]
        sheet << [ "Example caller", "9000000000", "skip me" ]
        sheet << [ "Asha", "+91 98765-43210", "From the portal" ]
        sheet << [ "Two", "9876543211 / 9988776655", nil ]
        sheet << [ "Science", "9.87654E+09", nil ]
      end

      post "/api/v1/prospects/import", params: { file: upload(csv) }, headers: auth(agent)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["created_count"]).to eq(1)
      expect(response.parsed_body["failed_count"]).to eq(2)
      prospect = Prospect.unscoped.find_by!(firm_id: firm.id, mobile: "+919876543210")
      expect(prospect.name).to eq("Asha")
      expect(prospect.status).to eq("new")
      expect(prospect.comment).to eq("From the portal")
    end

    it "rejects a second copy of a number and stops at the firm cap" do
      create(:prospect, firm:, mobile: "+919876543210")
      stub_const("Prospect::MAX_PER_FIRM", 2)
      csv = CSV.generate do |sheet|
        sheet << [ "Client number" ]
        sheet << [ "9876543210" ]
        sheet << [ "9876543211" ]
        sheet << [ "9876543212" ]
      end

      post "/api/v1/prospects/import", params: { file: upload(csv) }, headers: auth(manager)

      errors = response.parsed_body["results"].select { |row| row["status"] == "failed" }.map { |row| row["error"] }
      expect(errors).to include("This number is already in your list.")
      expect(errors).to include("Your firm already has 2 prospects.")
      expect(Prospect.unscoped.where(firm_id: firm.id).count).to eq(2)
    end

    it "links the same project code on every row that names it" do
      project = create(:project, firm:)
      csv = CSV.generate do |sheet|
        sheet << [ "Client number", "Project code" ]
        sheet << [ "9876543210", project.code ]
        sheet << [ "9876543211", project.code.downcase ]
      end

      post "/api/v1/prospects/import", params: { file: upload(csv) }, headers: auth(agent)

      expect(response).to have_http_status(:ok)
      expect(Prospect.unscoped.where(firm_id: firm.id, project_id: project.id).count).to eq(2)
    end

    it "explains that the sample row is skipped when that is the whole file" do
      post "/api/v1/prospects/import",
        params: { file: upload(Prospects::Import.template) },
        headers: auth(agent)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "message")).to include("Replace Example caller")
    end

    it "rejects an Excel workbook" do
      post "/api/v1/prospects/import",
        params: { file: upload("PK\x03\x04not-a-csv", name: "sheet.csv") },
        headers: auth(manager)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "message")).to include("Excel")
    end
  end

  describe "calling" do
    let!(:prospect) { create(:prospect, firm:, mobile: "+919876543210", status: "new", name: "Asha") }

    it "moves a missed call to Following and stores the next dial time" do
      when_at = 2.days.from_now.change(usec: 0)

      post "/api/v1/prospects/#{prospect.id}/followups",
        params: { connected: false, notes: "Switched off", next_action_at: when_at.iso8601 },
        headers: auth(agent), as: :json

      expect(response).to have_http_status(:created)
      prospect.reload
      expect(prospect.status).to eq("following")
      expect(prospect.next_action_at).to eq(when_at)
    end

    it "marks a missed call not interested without a next dial time" do
      post "/api/v1/prospects/#{prospect.id}/followups",
        params: { connected: false, notes: "Wrong number", mark_not_interested: true },
        headers: auth(agent), as: :json

      expect(response).to have_http_status(:created)
      expect(prospect.reload.status).to eq("not_interested")
      expect(prospect.next_action_at).to be_nil
    end

    it "keeps a connected not-sure call on Following" do
      post "/api/v1/prospects/#{prospect.id}/followups",
        params: { connected: true, notes: "Call back later", disposition: "not_sure" },
        headers: auth(agent), as: :json

      expect(response).to have_http_status(:created)
      expect(prospect.reload.status).to eq("following")
      expect(prospect.next_action_at).to be_nil
    end

    it "creates a lead when the client is interested and assigns an agent to themselves" do
      post "/api/v1/prospects/#{prospect.id}/followups",
        params: { connected: true, notes: "Ready to visit", disposition: "interested", lead: requirements },
        headers: auth(agent), as: :json

      expect(response).to have_http_status(:created)
      prospect.reload
      expect(prospect.status).to eq("interested")
      expect(prospect.lead.assigned_user).to eq(agent)
      expect(prospect.lead.mobile).to eq(prospect.mobile)
      expect(prospect.lead.notes).to include("Ready to visit")
      expect(prospect.lead.lead_source.name).to eq("Telecalling")
      expect(prospect.lead.lead_followups).to be_empty
      expect(response.parsed_body.dig("prospect", "lead_code")).to eq(prospect.lead.code)
      expect(response.parsed_body.dig("prospect", "lead_accessible")).to be(true)
    end

    it "does not change the prospect when that number already has a live sale lead" do
      create(:lead, :matchable, firm:, lead_status:, mobile: prospect.mobile, transaction_type: "sale",
        property_type:)

      post "/api/v1/prospects/#{prospect.id}/followups",
        params: { connected: true, notes: "Ready", disposition: "interested", lead: requirements },
        headers: auth(manager), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("duplicate_lead")
      expect(response.parsed_body.dig("error", "details", "lead_code")).to be_present
      expect(prospect.reload.status).to eq("new")
      expect(prospect.prospect_followups).to be_empty
      expect(Lead.unscoped.where(firm_id: firm.id, mobile: prospect.mobile).count).to eq(1)
    end
  end

  describe "the lead link" do
    it "shows the lead code to every user and the link only to someone who can open the lead" do
      lead = create(:lead, firm:, lead_status:, assigned_user: agent, mobile: "+919876543210")
      prospect = create(:prospect, firm:, status: "interested", lead:, mobile: lead.mobile, name: "Asha")
      headers = auth(other_agent)

      get "/api/v1/prospects?status=interested", headers: headers

      card = response.parsed_body["prospects"].first
      expect(card["lead_code"]).to eq(lead.code)
      expect(card["lead_accessible"]).to be(false)
      expect(card).not_to have_key("lead_id")
      expect(card).not_to have_key("mobile")

      get "/api/v1/prospects/#{prospect.id}/mobile", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("mobile" => lead.mobile)
    end
  end

  describe "move back and delete" do
    it "lets the assignee delete an untouched lead and return the prospect to Following" do
      lead = create(:lead, firm:, lead_status:, assigned_user: agent, mobile: "+919876543210")
      prospect = create(:prospect, firm:, status: "interested", lead:, mobile: lead.mobile)

      post "/api/v1/prospects/#{prospect.id}/move_to_following", headers: auth(agent), as: :json

      expect(response).to have_http_status(:ok)
      expect(prospect.reload.status).to eq("following")
      expect(prospect.lead_id).to be_nil
      expect(Lead.unscoped.exists?(lead.id)).to be(false)
    end

    it "refuses another agent, and refuses when the lead has a booking" do
      lead = create(:lead, firm:, lead_status:, assigned_user: agent, mobile: "+919876543210")
      booking = create(:booking, firm:, lead:)
      prospect = create(:prospect, firm:, status: "interested", lead:, mobile: lead.mobile)

      post "/api/v1/prospects/#{prospect.id}/move_to_following", headers: auth(other_agent), as: :json
      expect(response).to have_http_status(:forbidden)
      expect(Lead.unscoped.exists?(lead.id)).to be(true)

      post "/api/v1/prospects/#{prospect.id}/move_to_following", headers: auth(manager), as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("lead_worked")
      expect(prospect.reload.status).to eq("interested")
      expect(Lead.unscoped.exists?(lead.id)).to be(true)
      expect(Booking.unscoped.exists?(booking.id)).to be(true)
    end

    it "refuses when the lead has a follow-up" do
      lead = create(:lead, firm:, lead_status:, assigned_user: agent, mobile: "+919876543210")
      create(:lead_followup, firm:, lead:, user: agent)
      prospect = create(:prospect, firm:, status: "interested", lead:, mobile: lead.mobile)

      post "/api/v1/prospects/#{prospect.id}/move_to_following", headers: auth(agent), as: :json

      expect(response.parsed_body.dig("error", "code")).to eq("lead_worked")
      expect(Lead.unscoped.exists?(lead.id)).to be(true)
    end

    it "lets any user send Not interested back to Following" do
      prospect = create(:prospect, firm:, status: "not_interested", mobile: "+919876543210")

      post "/api/v1/prospects/#{prospect.id}/move_to_following", headers: auth(agent), as: :json

      expect(response).to have_http_status(:ok)
      expect(prospect.reload.status).to eq("following")
    end

    it "lets a manager delete the prospect and leave the lead" do
      lead = create(:lead, firm:, lead_status:, mobile: "+919876543210")
      prospect = create(:prospect, firm:, status: "interested", lead:, mobile: lead.mobile)

      delete "/api/v1/prospects/#{prospect.id}", headers: auth(agent)
      expect(response).to have_http_status(:forbidden)
      expect(Prospect.unscoped.exists?(prospect.id)).to be(true)

      delete "/api/v1/prospects/#{prospect.id}", headers: auth(manager)
      expect(response).to have_http_status(:no_content)
      expect(Prospect.unscoped.exists?(prospect.id)).to be(false)
      expect(Lead.unscoped.exists?(lead.id)).to be(true)
    end

    it "clears only the chosen statuses and leaves leads in place" do
      lead = create(:lead, firm:, lead_status:, mobile: "+919876543210")
      interested = create(:prospect, firm:, status: "interested", lead:, mobile: lead.mobile, name: "=cmd")
      create(:prospect, firm:, status: "new", mobile: "+919876543211")

      delete_headers = auth(agent)
      post "/api/v1/prospects/clear", params: { statuses: [ "interested" ] }, headers: delete_headers, as: :json
      expect(response).to have_http_status(:forbidden)

      headers = auth(manager)
      get "/api/v1/prospects/backup", params: { statuses: [ "interested" ] }, headers: headers
      expect(response.body).to include("'=cmd")
      expect(response.body).to include(lead.code)

      post "/api/v1/prospects/clear", params: { statuses: [ "interested" ] }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["deleted_count"]).to eq(1)
      expect(Prospect.unscoped.exists?(interested.id)).to be(false)
      expect(Prospect.unscoped.where(firm_id: firm.id, status: "new").count).to eq(1)
      expect(Lead.unscoped.exists?(lead.id)).to be(true)
    end
  end

  describe "search and tenancy" do
    it "searches name, number, and status across the list" do
      create(:prospect, firm:, name: "Asha", mobile: "+919876543210", status: "following")
      create(:prospect, firm:, name: "Rohan", mobile: "+919111112222", status: "new")

      get "/api/v1/prospects", params: { status: "new", q: "9876543210" }, headers: auth(agent)

      names = response.parsed_body["prospects"].map { |row| row["name"] }
      expect(names).to eq([ "Asha" ])
    end

    it "shows the newest call note on the list" do
      prospect = create(:prospect, firm:, name: "Asha", status: "following")
      create(:prospect_followup, prospect:, notes: "First try", created_at: 2.hours.ago)
      create(:prospect_followup, prospect:, notes: "Called again", created_at: 1.hour.ago)

      get "/api/v1/prospects", params: { status: "following" }, headers: auth(agent)

      row = response.parsed_body["prospects"].find { |item| item["id"] == prospect.id }
      expect(row["latest_note"]).to eq("Called again")
    end

    it "hides another firm's prospect" do
      other = create(:firm, status: :active)
      create(:subscription, firm: other, plan:)
      theirs = create(:prospect, firm: other)

      headers = auth(manager)
      patch "/api/v1/prospects/#{theirs.id}", params: { comment: "nope" }, headers: headers, as: :json
      expect(response).to have_http_status(:not_found)

      get "/api/v1/prospects/#{theirs.id}/mobile", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "locks name and number once the prospect is interested" do
      lead = create(:lead, firm:, lead_status:, mobile: "+919876543210")
      prospect = create(:prospect, firm:, status: "interested", lead:, mobile: lead.mobile, name: "Asha")

      patch "/api/v1/prospects/#{prospect.id}", params: { name: "Changed" }, headers: auth(manager), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("prospect_locked")
      expect(prospect.reload.name).to eq("Asha")
    end
  end
end
