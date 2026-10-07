# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin Facebook Page release" do
  before { sign_in_admin }

  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active) }
  let!(:owner) { create(:user, :super_admin, firm:) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let(:client) { instance_double(Facebook::GraphApiClient) }

  before do
    allow(Facebook::GraphApiClient).to receive(:new).and_return(client)
    allow(client).to receive(:unsubscribe_page).and_return(true)
    allow(client).to receive(:subscribed_apps).and_return(true)
  end

  def deliverer = Notifications::Deliverer.current

  def broker_auth(user)
    post "/api/v1/auth/otp", params: { mobile: user.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify", params: { request_id:, code: deliverer.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
  end

  it "lists the firm's Pages on the firm screen" do
    connection = create(:facebook_connection, firm:, connected_by_user: owner)
    create(:facebook_page, firm:, facebook_connection: connection, page_name: "Harbour Page",
      page_id: "page-listed", subscribed: true, status: "active")

    get admin_firm_path(firm)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Harbour Page")
    expect(response.body).to include("page-listed")
    expect(response.body).to include("Release")
  end

  it "releases a held Page so another firm can connect it" do
    connection = create(:facebook_connection, firm:, connected_by_user: owner)
    page = create(:facebook_page, firm:, facebook_connection: connection, page_id: "page-held",
      page_name: "Harbour Page", subscribed: true, status: "active", page_access_token: "page-token")
    form = create(:facebook_lead_form, firm:, facebook_page: page)
    import = create(:facebook_lead_import, firm:, facebook_page: page, facebook_lead_form: form)

    delete release_admin_firm_facebook_page_path(firm, page)

    expect(response).to redirect_to(admin_firm_path(firm))
    expect(client).to have_received(:unsubscribe_page).with("page-held")
    expect(FacebookPage.across_firms.find_by(id: page.id)).to be_nil
    expect(FacebookLeadForm.across_firms.find_by(id: form.id)).to be_nil
    expect(FacebookLeadImport.across_firms.find_by(id: import.id)).to be_nil
    expect(AuditEvent.find_by(action: "facebook.page_released", firm_id: firm.id).metadata)
      .to include("page_name" => "Harbour Page")

    buyer = create(:firm, status: :active)
    buyer_owner = create(:user, :super_admin, firm: buyer)
    create(:subscription, firm: buyer, plan:)
    attempt = create(:facebook_oauth_attempt, firm: buyer, user: buyer_owner, status: "completed",
      nonce_digest: Digest::SHA256.hexdigest("n" * 32))
    Current.set(firm: buyer) do
      attempt.update!(result: FacebookOauthAttempt.dump_oauth_result(
        long_lived_token: "super-secret-user-token",
        expires_at: 60.days.from_now,
        fb_user_id: "fb-buyer",
        fb_user_name: "Buyer",
        token_kind: "system_access",
        pages: [ { page_id: "page-held", page_name: "Harbour Page", page_access_token: "new-page-token" } ]
      ))
    end

    post "/api/v1/facebook/connections",
      params: { attempt_id: attempt.id, nonce: "n" * 32 },
      headers: broker_auth(buyer_owner), as: :json

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("super-secret")
    expect(FacebookPage.across_firms.find_by(page_id: "page-held").firm_id).to eq(buyer.id)
  end

  it "still releases the Page when Meta cannot be reached" do
    connection = create(:facebook_connection, firm:, connected_by_user: owner)
    page = create(:facebook_page, firm:, facebook_connection: connection, page_id: "page-slow",
      page_name: "Slow Page", page_access_token: "page-token", subscribed: true, status: "active")
    allow(client).to receive(:unsubscribe_page).and_raise(Faraday::TimeoutError)

    delete release_admin_firm_facebook_page_path(firm, page)

    expect(response).to redirect_to(admin_firm_path(firm))
    expect(FacebookPage.across_firms.find_by(id: page.id)).to be_nil
  end
end
