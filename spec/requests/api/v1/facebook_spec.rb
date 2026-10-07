# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 Facebook Lead Ads" do
  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:owner) { create(:user, :super_admin, firm:) }
  let!(:manager) { create(:user, :manager, firm:) }
  let!(:agent) { create(:user, firm:, role: :agent) }
  let(:client) { instance_double(Facebook::GraphApiClient) }

  def deliverer = Notifications::Deliverer.current

  def auth(user)
    post "/api/v1/auth/otp", params: { mobile: user.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify", params: { request_id:, code: deliverer.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
  end

  def page_grant(id: "page-1", name: "Harbour Page", token: "super-secret-page-token")
    { page_id: id, page_name: name, page_access_token: token }
  end

  def completed_attempt(user, pages:, nonce: "n" * 32, fb_user_id: "fb-new")
    attempt = create(:facebook_oauth_attempt, firm: user.firm, user:, status: "completed",
      nonce_digest: Digest::SHA256.hexdigest(nonce))
    Current.set(firm: user.firm) do
      attempt.update!(result: FacebookOauthAttempt.dump_oauth_result(
        long_lived_token: "super-secret-user-token",
        expires_at: 60.days.from_now,
        fb_user_id:,
        fb_user_name: "Harbour",
        token_kind: "system_access",
        pages:
      ))
    end
    [ attempt, nonce ]
  end

  before do
    allow(Facebook::GraphApiClient).to receive(:new).and_return(client)
    allow(client).to receive(:subscribed_apps).and_return(true)
    allow(client).to receive(:unsubscribe_page).and_return(true)
  end

  it "refuses an agent and a manager" do
    [ agent, manager ].each do |user|
      get "/api/v1/facebook/integration", headers: auth(user)
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("forbidden_role")
    end
  end

  it "hides tokens and another firm's pages" do
    connection = create(:facebook_connection, firm:, connected_by_user: owner, access_token: "super-secret-user-token")
    page = create(:facebook_page, firm:, facebook_connection: connection, page_access_token: "super-secret-page-token",
      subscribed: true, status: "active")
    other = create(:firm)
    other_page = create(:facebook_page, firm: other, page_access_token: "other-secret-page-token")

    get "/api/v1/facebook/integration", headers: auth(owner)
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("super-secret")
    expect(response.parsed_body["configured"]).to eq(Facebook::Credentials.configured?)
    expect(response.parsed_body.dig("connection", "id")).to eq(connection.id)

    post "/api/v1/facebook/pages/#{other_page.id}/subscribe", headers: auth(owner)
    expect(response).to have_http_status(:not_found)
    post "/api/v1/facebook/pages/#{page.id}/subscribe", headers: auth(owner)
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("super-secret")
    expect(FacebookPage.across_firms.find(page.id)).to be_subscribed
  end

  describe "an invalid connection" do
    let!(:connection) do
      create(:facebook_connection, firm:, connected_by_user: owner, status: "invalid",
        access_token: "super-secret-user-token")
    end
    let!(:page) do
      create(:facebook_page, firm:, facebook_connection: connection, page_name: "Harbour Page",
        subscribed: true, status: "active")
    end

    it "shows the connection and its Pages" do
      get "/api/v1/facebook/integration", headers: auth(owner)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("connection", "id")).to eq(connection.id)
      expect(response.parsed_body.dig("connection", "status")).to eq("invalid")
      expect(response.parsed_body["pages"].map { |row| row["page_name"] }).to eq([ "Harbour Page" ])
      expect(response.body).not_to include("super-secret")
    end

    it "returns facebook_error when subscribing times out" do
      Current.set(firm:) { page.update!(subscribed: false, status: "unsubscribed") }
      allow(client).to receive(:subscribed_apps).and_raise(Faraday::TimeoutError)
      post "/api/v1/facebook/pages/#{page.id}/subscribe", headers: auth(owner), as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("error", "code")).to eq("facebook_error")
      expect(FacebookPage.across_firms.find(page.id)).not_to be_subscribed
    end

    it "runs a health check and disconnects" do
      allow(Facebook::TokenManager).to receive(:health_check!).and_return(false)
      headers = auth(owner)

      post "/api/v1/facebook/connection/health_check", headers:, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["ok"]).to be false
      expect(response.parsed_body.dig("connection", "status")).to eq("invalid")

      delete "/api/v1/facebook/connection", headers:, as: :json
      expect(response).to have_http_status(:ok)
      expect(FacebookConnection.across_firms.find(connection.id)).to be_connection_disconnected
      expect(response.parsed_body["connection"]).to be_nil
      expect(FacebookPage.across_firms.find(page.id).page_access_token).to be_nil
    end
  end

  describe "confirm" do
    it "voids a wrong nonce, and the right nonce cannot use it afterwards" do
      attempt, nonce = completed_attempt(owner, pages: [ page_grant ])

      post "/api/v1/facebook/connections", params: { attempt_id: attempt.id, nonce: "m" * 32 },
        headers: auth(owner), as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("error", "code")).to eq("not_yours")
      reloaded = FacebookOauthAttempt.across_firms.find(attempt.id)
      expect(reloaded).to be_failed
      expect(reloaded.error_code).to eq("wrong_browser")
      expect(reloaded.result).to be_nil

      post "/api/v1/facebook/connections", params: { attempt_id: attempt.id, nonce: },
        headers: auth(owner), as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("error", "code")).to eq("wrong_browser")
    end

    it "voids an attempt confirmed by someone else" do
      attempt, nonce = completed_attempt(owner, pages: [ page_grant ])
      post "/api/v1/facebook/connections", params: { attempt_id: attempt.id, nonce: },
        headers: auth(manager), as: :json
      expect(response).to have_http_status(:forbidden)

      other = create(:firm)
      create(:subscription, firm: other, plan:)
      outsider = create(:user, :super_admin, firm: other)
      post "/api/v1/facebook/connections", params: { attempt_id: attempt.id, nonce: },
        headers: auth(outsider), as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("error", "code")).to eq("not_yours")
      expect(FacebookOauthAttempt.across_firms.find(attempt.id)).to be_failed
    end

    it "refuses an expired attempt and a second confirm" do
      attempt, nonce = completed_attempt(owner, pages: [ page_grant ])
      Current.set(firm:) { attempt.update!(expires_at: 1.minute.ago) }
      post "/api/v1/facebook/connections", params: { attempt_id: attempt.id, nonce: },
        headers: auth(owner), as: :json
      expect(response.parsed_body.dig("error", "code")).to eq("expired")

      fresh, fresh_nonce = completed_attempt(owner, pages: [ page_grant ], fb_user_id: "fb-once")
      post "/api/v1/facebook/connections", params: { attempt_id: fresh.id, nonce: fresh_nonce },
        headers: auth(owner), as: :json
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("super-secret")
      expect(FacebookOauthAttempt.across_firms.find(fresh.id)).to be_consumed
      expect(FacebookOauthAttempt.across_firms.find(fresh.id).result).to be_nil

      post "/api/v1/facebook/connections", params: { attempt_id: fresh.id, nonce: fresh_nonce },
        headers: auth(owner), as: :json
      expect(response.parsed_body.dig("error", "code")).to eq("already_used")
    end

    it "keeps subscribed pages and refreshes them after the connection is stored" do
      connection = create(:facebook_connection, firm:, connected_by_user: owner, fb_user_id: "fb-old",
        access_token: "super-secret-user-token")
      subscribed_at = 3.days.ago.change(usec: 0)
      page = create(:facebook_page, firm:, facebook_connection: connection, page_id: "page-1",
        page_name: "Harbour Page", subscribed: true, status: "active", subscribed_at:,
        page_access_token: "super-secret-page-token")
      left = create(:facebook_page, firm:, facebook_connection: connection, page_id: "page-left",
        subscribed: false, status: "unsubscribed", page_access_token: "left-behind-token")
      depth = nil
      allow(client).to receive(:subscribed_apps) do
        depth = ActiveRecord::Base.connection.open_transactions
        active = FacebookConnection.across_firms.find_by(firm_id: firm.id, status: "active")
        expect(active.fb_user_id).to eq("fb-new")
        true
      end
      attempt, nonce = completed_attempt(owner, pages: [ page_grant ])

      post "/api/v1/facebook/connections", params: { attempt_id: attempt.id, nonce: },
        headers: auth(owner), as: :json

      expect(response).to have_http_status(:ok)
      expect(depth).to eq(ActiveRecord::Base.connection.open_transactions)
      expect(client).to have_received(:subscribed_apps).with("page-1").once
      page = FacebookPage.across_firms.find(page.id)
      expect(page).to be_subscribed
      expect(page).to be_page_active
      expect(page.subscribed_at).to be_within(1.second).of(subscribed_at)
      expect(page.facebook_connection_id).not_to eq(connection.id)
      expect(FacebookConnection.across_firms.find(connection.id)).to be_connection_disconnected
      left = FacebookPage.across_firms.find(left.id)
      expect(left.page_access_token).to be_nil
      expect(left.facebook_connection_id).to eq(connection.id)
    end

    it "leaves the page subscribed when the refresh fails and warns" do
      connection = create(:facebook_connection, firm:, connected_by_user: owner, fb_user_id: "fb-old")
      page = create(:facebook_page, firm:, facebook_connection: connection, page_id: "page-1",
        subscribed: true, status: "active")
      allow(client).to receive(:subscribed_apps).and_raise(Facebook::Errors::WebhookSubscriptionError.new("no"))
      attempt, nonce = completed_attempt(owner, pages: [ page_grant(name: "Harbour Page") ])

      post "/api/v1/facebook/connections", params: { attempt_id: attempt.id, nonce: },
        headers: auth(owner), as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["warnings"]).to contain_exactly(
        a_hash_including("kind" => "subscription_refresh", "page_name" => "Harbour Page")
      )
      page = FacebookPage.across_firms.find(page.id)
      expect(page).to be_subscribed
      expect(page).to be_page_active
      expect(page.status_message).to eq(Facebook::StoreConnection::SUBSCRIPTION_MESSAGE)
    end

    it "refuses a grant that drops a subscribed page and keeps the old connection" do
      connection = create(:facebook_connection, firm:, connected_by_user: owner, fb_user_id: "fb-old",
        access_token: "super-secret-user-token")
      create(:facebook_page, firm:, facebook_connection: connection, page_id: "page-keep",
        page_name: "Keep me", subscribed: true, status: "active")
      attempt, nonce = completed_attempt(owner, pages: [ page_grant(id: "page-other", name: "Other") ])

      post "/api/v1/facebook/connections", params: { attempt_id: attempt.id, nonce: },
        headers: auth(owner), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("error", "code")).to eq("missing_subscribed_pages")
      expect(response.parsed_body.dig("error", "details", "pages")).to eq([ "Keep me" ])
      expect(FacebookConnection.across_firms.find(connection.id)).to be_connection_active
      expect(FacebookOauthAttempt.across_firms.find(attempt.id)).to be_failed
      expect(FacebookOauthAttempt.across_firms.find(attempt.id).result).to be_nil
    end

    it "refuses when every granted Page is held, including one that is only subscribed" do
      other = create(:firm)
      create(:facebook_page, firm: other, page_id: "page-1", page_name: "Theirs",
        page_access_token: nil, subscribed: true, status: "active")
      attempt, nonce = completed_attempt(owner, pages: [ page_grant ])

      post "/api/v1/facebook/connections", params: { attempt_id: attempt.id, nonce: },
        headers: auth(owner), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("error", "code")).to eq("page_taken")
      expect(response.parsed_body.dig("error", "details", "pages")).to eq([ "Theirs" ])
      expect(FacebookConnection.across_firms.where(firm_id: firm.id, status: "active")).to be_empty
      expect(FacebookOauthAttempt.across_firms.find(attempt.id)).to be_failed
      expect(FacebookPage.across_firms.find_by(page_id: "page-1").firm_id).to eq(other.id)
    end

    it "keeps a subscribed page when reconnecting after access has stopped" do
      connection = create(:facebook_connection, firm:, connected_by_user: owner, fb_user_id: "fb-old",
        status: "invalid", access_token: "super-secret-user-token")
      page = create(:facebook_page, firm:, facebook_connection: connection, page_id: "page-1",
        page_name: "Harbour Page", subscribed: true, status: "active",
        page_access_token: "super-secret-page-token")
      attempt, nonce = completed_attempt(owner, pages: [ page_grant ])

      post "/api/v1/facebook/connections", params: { attempt_id: attempt.id, nonce: },
        headers: auth(owner), as: :json

      expect(response).to have_http_status(:ok)
      expect(client).to have_received(:subscribed_apps).with("page-1").once
      page = FacebookPage.across_firms.find(page.id)
      expect(page).to be_subscribed
      expect(page).to be_page_active
      expect(FacebookConnection.across_firms.find(connection.id)).to be_connection_disconnected
      expect(response.parsed_body.dig("connection", "status")).to eq("active")
    end

    it "refuses a grant that drops a subscribed page of an invalid connection" do
      connection = create(:facebook_connection, firm:, connected_by_user: owner, status: "invalid")
      create(:facebook_page, firm:, facebook_connection: connection, page_id: "page-keep",
        page_name: "Keep me", subscribed: true, status: "active")
      attempt, nonce = completed_attempt(owner, pages: [ page_grant(id: "page-other", name: "Other") ])

      post "/api/v1/facebook/connections", params: { attempt_id: attempt.id, nonce: },
        headers: auth(owner), as: :json

      expect(response.parsed_body.dig("error", "code")).to eq("missing_subscribed_pages")
      expect(FacebookConnection.across_firms.find(connection.id)).to be_connection_invalid
    end

    it "skips a Page another firm holds and connects the rest" do
      other = create(:firm)
      create(:facebook_page, firm: other, page_id: "page-1", page_name: "Theirs",
        page_access_token: "their-token", subscribed: false)
      attempt, nonce = completed_attempt(owner, pages: [
        page_grant(id: "page-1", name: "Theirs"),
        page_grant(id: "page-2", name: "Ours")
      ])

      post "/api/v1/facebook/connections", params: { attempt_id: attempt.id, nonce: },
        headers: auth(owner), as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["warnings"]).to include(
        a_hash_including("kind" => "page_taken", "page_name" => "Theirs")
      )
      expect(FacebookPage.across_firms.find_by(firm_id: firm.id, page_id: "page-2")).to be_present
      expect(FacebookPage.across_firms.find_by(page_id: "page-1").firm_id).to eq(other.id)
      expect(FacebookOauthAttempt.across_firms.find(attempt.id)).to be_consumed
    end

    it "releases a stale Page and connects it" do
      other = create(:firm)
      stale = create(:facebook_page, firm: other, page_id: "page-1", page_name: "Left behind",
        page_access_token: nil, subscribed: false, status: "unsubscribed")
      stale_form = create(:facebook_lead_form, firm: other, facebook_page: stale)
      stale_import = create(:facebook_lead_import, firm: other, facebook_page: stale)
      attempt, nonce = completed_attempt(owner, pages: [ page_grant(name: "Harbour Page") ])

      post "/api/v1/facebook/connections", params: { attempt_id: attempt.id, nonce: },
        headers: auth(owner), as: :json

      expect(response).to have_http_status(:ok)
      expect(FacebookPage.across_firms.find_by(id: stale.id)).to be_nil
      expect(FacebookLeadForm.across_firms.find_by(id: stale_form.id)).to be_nil
      expect(FacebookLeadImport.across_firms.find_by(id: stale_import.id)).to be_nil
      expect(FacebookPage.across_firms.find_by(page_id: "page-1").firm_id).to eq(firm.id)
      released = AuditEvent.find_by(action: "facebook.page_released", firm_id: other.id)
      expect(released.metadata).to include("page_id" => "page-1", "page_name" => "Left behind")
    end

    it "answers already_connected when a concurrent connect wins the unique index" do
      create(:facebook_connection, firm:, connected_by_user: owner, status: "active")
      allow(Facebook::StoreConnection).to receive(:new).and_wrap_original do |method, *args, **kwargs|
        service = method.call(*args, **kwargs)
        allow(service).to receive(:disconnect_others!)
        service
      end
      attempt, nonce = completed_attempt(owner, pages: [ page_grant ])

      post "/api/v1/facebook/connections", params: { attempt_id: attempt.id, nonce: },
        headers: auth(owner), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("error", "code")).to eq("already_connected")
      expect(FacebookConnection.across_firms.where(firm_id: firm.id, status: "active").count).to eq(1)
      expect(FacebookOauthAttempt.across_firms.find(attempt.id)).to be_completed
    end
  end

  describe "forms and imports" do
    let(:connection) { create(:facebook_connection, firm:, connected_by_user: owner) }
    let(:page) { create(:facebook_page, firm:, facebook_connection: connection, subscribed: true, status: "active") }
    let(:project) { create(:project, firm:) }
    let(:form) { create(:facebook_lead_form, firm:, facebook_page: page, project:) }

    it "rejects a form save that is not ready" do
      headers = auth(owner)
      bare = create(:facebook_lead_form, firm:, facebook_page: page, project: nil, property: nil)
      patch "/api/v1/facebook/forms/#{bare.id}", params: { active: true }, headers:, as: :json
      expect(response.parsed_body.dig("error", "message")).to eq("Pick a project or property for this form")

      patch "/api/v1/facebook/forms/#{bare.id}", params: { active: false }, headers:, as: :json
      expect(response).to have_http_status(:ok)
      expect(FacebookLeadForm.across_firms.find(bare.id).active).to be false

      Current.set(firm:) { project.update!(status: "archived") }
      patch "/api/v1/facebook/forms/#{form.id}", params: { project_id: project.id }, headers:, as: :json
      expect(response.parsed_body.dig("error", "message")).to include("no longer active")

      Current.set(firm:) { project.update!(status: "active") }
      patch "/api/v1/facebook/forms/#{form.id}", params: {
        project_id: project.id,
        field_mappings: { "custom" => "email" }
      }, headers:, as: :json
      expect(response.parsed_body.dig("error", "message")).to eq("Map Name and Mobile")

      patch "/api/v1/facebook/forms/#{form.id}", params: {
        project_id: project.id,
        field_mappings: { "full_name" => "name", "phone_number" => "mobile" }
      }, headers:, as: :json
      expect(response).to have_http_status(:ok)
      expect(AuditEvent.order(:created_at).last.action).to eq("facebook.form.update")
      expect(response.body).not_to include("page_access_token")
    end

    it "refuses a form another firm owns" do
      headers = auth(owner)
      other = create(:firm)
      create(:facebook_lead_form, firm: other, form_id: "taken-form")
      Current.set(firm:) do
        page.update!(form_catalog: [ { "form_id" => "taken-form", "form_name" => "Taken", "status" => "ACTIVE", "questions" => [] } ])
      end
      post "/api/v1/facebook/pages/#{page.id}/forms", params: { meta_form_id: "taken-form" }, headers:, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig("error", "code")).to eq("already_mapped")
    end

    it "saves the mappings the form editor displays" do
      headers = auth(owner)
      shown = create(:facebook_lead_form, firm:, facebook_page: page, project:, field_mappings: {},
        questions: [
          { "key" => "full_name", "label" => "Full name", "type" => "FULL_NAME" },
          { "key" => "phone_number", "label" => "Phone", "type" => "PHONE" },
          { "key" => "email_address", "label" => "Email", "type" => "EMAIL" }
        ])
      get "/api/v1/facebook/forms/#{shown.id}", headers:, as: :json
      displayed = response.parsed_body.dig("form", "ui_field_mappings")
      expect(response.parsed_body.dig("form", "explicit_mappings")).to be false
      expect(displayed).to include("email_address" => "email", "full_name" => "name", "phone_number" => "mobile")

      patch "/api/v1/facebook/forms/#{shown.id}", params: {
        active: true, project_id: project.id, field_mappings: displayed
      }, headers:, as: :json

      expect(response).to have_http_status(:ok)
      saved = FacebookLeadForm.across_firms.find(shown.id)
      expect(saved.field_mappings).to include("email_address" => "email")
      expect(saved.explicit_mappings?).to be true
    end

    it "rejects a newly chosen lead source that is turned off" do
      headers = auth(owner)
      chosen = create(:lead_source, name: "Old ads", active: true)
      Current.set(firm:) { form.update!(lead_source: chosen) }
      chosen.update!(active: false)

      patch "/api/v1/facebook/forms/#{form.id}", params: {
        project_id: project.id, lead_source_id: chosen.id, active: true
      }, headers:, as: :json
      expect(response).to have_http_status(:ok)

      other_source = create(:lead_source, name: "Closed ads", active: false)
      patch "/api/v1/facebook/forms/#{form.id}", params: {
        project_id: project.id, lead_source_id: other_source.id, active: true
      }, headers:, as: :json
      expect(response.parsed_body.dig("error", "message")).to eq("The chosen lead source is turned off")
    end

    it "retries a dead import" do
      import = create(:facebook_lead_import, firm:, facebook_page: page, facebook_lead_form: form,
        status: "dead", retry_count: 5, error_message: "Pick a project or property for this form")
      other = create(:firm)
      hidden = create(:facebook_lead_import, firm: other, status: "dead")

      post "/api/v1/facebook/imports/#{hidden.id}/retry", headers: auth(owner)
      expect(response).to have_http_status(:not_found)

      post "/api/v1/facebook/imports/#{import.id}/retry", headers: auth(owner)
      expect(response).to have_http_status(:ok)
      import = FacebookLeadImport.across_firms.find(import.id)
      expect(import).to be_pending
      expect(import.retry_count).to eq(0)
      expect(import.next_attempt_at).to be_nil
      expect(Facebook::ProcessLeadJob).to have_been_enqueued.with(firm.id, import.id)
    end
  end
end
