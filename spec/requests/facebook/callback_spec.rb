# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Facebook OAuth callback" do
  let(:origin) { "https://brokers.example.com" }
  let(:service) { instance_double(Facebook::OauthService) }

  before do
    allow(Facebook::Credentials).to receive(:web_origin).and_return(origin)
    allow(Facebook::OauthService).to receive(:new).and_return(service)
  end

  def attempt_row(id)
    FacebookOauthAttempt.across_firms.find(id)
  end

  it "sends a bad state back to the app and nowhere else" do
    get "/facebook/callback", params: { state: "not-a-state", code: "abc", redirect: "https://evil.example/steal" }

    expect(response).to redirect_to("#{origin}/settings/facebook?facebook_error=expired")
    expect(response.location).to start_with("#{origin}/")
  end

  it "does not change an attempt that is no longer started" do
    attempt = create(:facebook_oauth_attempt, status: "completed")
    Current.set(firm: attempt.firm) do
      attempt.update!(result: FacebookOauthAttempt.dump_oauth_result(
        long_lived_token: "kept-token", expires_at: nil, fb_user_id: "fb-1",
        fb_user_name: "Harbour", token_kind: "system_access", pages: []
      ))
    end

    get "/facebook/callback", params: { state: Facebook::State.encrypt(attempt.id), code: "again" }

    reloaded = attempt_row(attempt.id)
    expect(reloaded).to be_completed
    expect(reloaded.result).to be_present
    expect(response.location).to include("facebook_error=expired")
    expect(response.location).to start_with("#{origin}/")
  end

  it "records a short-lived token without putting Meta's text in the url" do
    attempt = create(:facebook_oauth_attempt, status: "started")
    allow(service).to receive(:exchange_code).and_raise(
      Facebook::Errors::ShortLivedTokenError.new("token abc was short lived")
    )

    get "/facebook/callback", params: { state: Facebook::State.encrypt(attempt.id), code: "abc" }

    expect(attempt_row(attempt.id).error_code).to eq("short_lived_token")
    expect(attempt_row(attempt.id)).to be_failed
    expect(response.location).to include("facebook_attempt=#{attempt.id}")
    expect(response.location).not_to include("short")
    expect(response.location).to start_with("#{origin}/")
  end

  it "marks a denial and stores a successful exchange" do
    denied = create(:facebook_oauth_attempt, status: "started")
    get "/facebook/callback", params: { state: Facebook::State.encrypt(denied.id), error: "access_denied" }
    expect(attempt_row(denied.id).error_code).to eq("denied")
    expect(response.location).not_to include("access_denied")

    attempt = create(:facebook_oauth_attempt, status: "started")
    allow(service).to receive(:exchange_code).and_return(
      long_lived_token: "user-token", expires_at: 30.days.from_now, fb_user_id: "fb-9",
      fb_user_name: "Harbour", token_kind: "user_access", pages: []
    )
    get "/facebook/callback", params: { state: Facebook::State.encrypt(attempt.id), code: "ok" }
    expect(attempt_row(attempt.id)).to be_completed
    expect(response.location).to eq("#{origin}/settings/facebook?facebook_attempt=#{attempt.id}")
  end
end
