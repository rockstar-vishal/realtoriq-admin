# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 trainings" do
  let(:plan) { create(:plan, max_devices: 3, max_users: 5) }
  let(:firm) { create(:firm, :with_channels, status: :active) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:user) { create(:user, :super_admin, firm:) }

  def tokens_for(target = user, device_id: "device-1")
    post "/api/v1/auth/otp", params: { mobile: target.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify",
      params: {
        request_id:, code: deliverer.last.code,
        device: { device_id:, device_name: "Web", platform: "web" }
      },
      as: :json
    response.parsed_body
  end

  def auth_headers(target = user, device_id: "device-1")
    { "Authorization" => "Bearer #{tokens_for(target, device_id:)['access_token']}" }
  end

  describe "GET /api/v1/trainings" do
    it "lists live trainings, newest first" do
      older = create(:training, :active, title: "Older", published_at: 3.days.ago)
      newer = create(:training, :active, title: "Newer", published_at: 1.hour.ago)

      get "/api/v1/trainings", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["trainings"].map { |t| t["id"] }).to eq([ newer.id, older.id ])
      expect(response.parsed_body["trainings"].first["banner_url"]).to be_present
      expect(response.parsed_body["meta"]["total_count"]).to eq(2)
    end

    it "hides drafts, archived and expired trainings" do
      create(:training, title: "Draft one")
      create(:training, :archived, title: "Archived one")
      create(:training, :active, title: "Expired one", valid_upto: 1.day.ago.to_date)

      get "/api/v1/trainings", headers: auth_headers

      expect(response.parsed_body["trainings"]).to be_empty
    end

    it "shows one on its last valid day" do
      create(:training, :active, valid_upto: Date.current)

      get "/api/v1/trainings", headers: auth_headers

      expect(response.parsed_body["trainings"].size).to eq(1)
    end

    it "shows the same training to a broker in another firm" do
      training = create(:training, :active)
      other_firm = create(:firm, :with_channels, status: :active)
      create(:subscription, firm: other_firm, plan:)
      outsider = create(:user, :super_admin, firm: other_firm)

      get "/api/v1/trainings", headers: auth_headers(outsider, device_id: "device-2")

      expect(response.parsed_body["trainings"].map { |t| t["id"] }).to eq([ training.id ])
    end

    it "is open to an agent" do
      create(:training, :active)
      agent = create(:user, firm:, role: :agent)

      get "/api/v1/trainings", headers: auth_headers(agent, device_id: "device-3")

      expect(response).to have_http_status(:ok)
    end

    it "needs a token" do
      get "/api/v1/trainings"

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body.dig("error", "code")).to eq("unauthorized")
    end
  end

  describe "GET /api/v1/trainings/:id" do
    # pdf.js fetches the guide. A redirect to storage answers 200 and omits
    # Access-Control-Allow-Origin, so the browser throws the file away. The
    # proxy URL stays on the API, which already allows the app origin.
    it "streams the guide from the API" do
      training = create(:training, :active)

      get "/api/v1/trainings/#{training.id}", headers: auth_headers

      url = response.parsed_body.dig("training", "document_url")
      expect(url).to include("/rails/active_storage/blobs/proxy/")
      expect(response.parsed_body.dig("training", "podcast_url")).to include("/rails/active_storage/blobs/redirect/")

      get URI.parse(url).path, headers: { "Origin" => "http://localhost:3000" }

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/pdf")
      expect(response.body).to start_with("%PDF")
      expect(response.headers["Access-Control-Allow-Origin"]).to eq("http://localhost:3000")
    end

    it "returns what the detail screen needs" do
      admin = create(:admin_user, name: "Priya Ops")
      training = create(:training, :active, created_by_admin_user: admin,
                                            podcast_duration_seconds: 1200)

      get "/api/v1/trainings/#{training.id}", headers: auth_headers

      payload = response.parsed_body["training"]
      expect(payload["intro_text"]).to be_present
      expect(payload["document_url"]).to be_present
      expect(payload["podcast_url"]).to be_present
      expect(payload["created_by_name"]).to eq("Priya Ops")
      expect(payload["podcast_duration_seconds"]).to eq(1200)
      expect(payload["note"]).to be_nil
    end

    it "prefers an uploaded podcast over a pasted link" do
      training = create(:training, :active, podcast_url: "https://cdn.example.com/a.mp3")

      get "/api/v1/trainings/#{training.id}", headers: auth_headers

      expect(response.parsed_body.dig("training", "podcast_url")).to include("/rails/active_storage/")
    end

    it "falls back to the pasted link when no file is attached" do
      training = create(:training, :active, podcast_url: "https://cdn.example.com/a.mp3")
      training.podcast.purge

      get "/api/v1/trainings/#{training.id}", headers: auth_headers

      expect(response.parsed_body.dig("training", "podcast_url")).to eq("https://cdn.example.com/a.mp3")
    end

    it "returns the caller's own note" do
      training = create(:training, :active)
      put "/api/v1/trainings/#{training.id}/note",
        params: { body: "Saturday: pre-approval slot" }, headers: auth_headers, as: :json

      get "/api/v1/trainings/#{training.id}", headers: auth_headers

      expect(response.parsed_body.dig("training", "note", "body")).to eq("Saturday: pre-approval slot")
    end

    it "404s for a training that isn't live" do
      training = create(:training, :archived)

      get "/api/v1/trainings/#{training.id}", headers: auth_headers

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig("error", "code")).to eq("not_found")
    end
  end

  describe "PUT /api/v1/trainings/:id/note" do
    let(:training) { create(:training, :active) }

    it "creates a note, then updates it in place" do
      headers = auth_headers

      put "/api/v1/trainings/#{training.id}/note", params: { body: "first" }, headers:, as: :json
      expect(response).to have_http_status(:ok)

      put "/api/v1/trainings/#{training.id}/note", params: { body: "second" }, headers:, as: :json

      expect(response.parsed_body.dig("note", "body")).to eq("second")
      expect(TrainingNote.across_firms.where(user_id: user.id, training_id: training.id).count).to eq(1)
    end

    it "clears the note when the body comes back empty" do
      headers = auth_headers
      put "/api/v1/trainings/#{training.id}/note", params: { body: "something" }, headers:, as: :json

      put "/api/v1/trainings/#{training.id}/note", params: { body: "" }, headers:, as: :json

      expect(response.parsed_body["note"]).to be_nil
      expect(TrainingNote.across_firms.count).to eq(0)
    end

    it "refuses a body over the cap rather than truncating it" do
      put "/api/v1/trainings/#{training.id}/note",
        params: { body: "x" * 20_001 }, headers: auth_headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("note_too_long")
    end

    it "refuses a body that isn't text instead of wiping the note" do
      headers = auth_headers
      put "/api/v1/trainings/#{training.id}/note", params: { body: "keep me" }, headers:, as: :json

      put "/api/v1/trainings/#{training.id}/note", params: { body: { a: 1 } }, headers:, as: :json

      expect(response).to have_http_status(:bad_request)
      expect(TrainingNote.across_firms.count).to eq(1)
    end

    it "keeps two brokers' notes apart" do
      colleague = create(:user, firm:, role: :manager)

      put "/api/v1/trainings/#{training.id}/note",
        params: { body: "mine" }, headers: auth_headers, as: :json
      put "/api/v1/trainings/#{training.id}/note",
        params: { body: "theirs" }, headers: auth_headers(colleague, device_id: "device-4"), as: :json

      get "/api/v1/trainings/#{training.id}", headers: auth_headers
      expect(response.parsed_body.dig("training", "note", "body")).to eq("mine")
    end

    it "404s when the training isn't live" do
      archived = create(:training, :archived)

      put "/api/v1/trainings/#{archived.id}/note",
        params: { body: "hello" }, headers: auth_headers, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end
end
