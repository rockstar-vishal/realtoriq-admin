# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Facebook handoff start" do
  let(:origin) { "https://brokers.example.com" }
  let(:service) { instance_double(Facebook::OauthService) }

  before do
    allow(Facebook::Credentials).to receive(:web_origin).and_return(origin)
    allow(Facebook::OauthService).to receive(:new).and_return(service)
  end

  def handoff(ticket, **attrs)
    create(:facebook_oauth_attempt, {
      handoff: true,
      handoff_ticket_digest: Digest::SHA256.hexdigest(ticket),
      handoff_expires_at: 10.minutes.from_now
    }.merge(attrs))
  end

  it "uses a ticket once and sends Facebook the attempt" do
    ticket = SecureRandom.urlsafe_base64(32)
    attempt = handoff(ticket)
    seen = nil
    expect(service).to receive(:authorization_url).once do |state:|
      seen = state
      "https://www.facebook.com/dialog/oauth"
    end

    get "/facebook/start", params: { ticket: }

    expect(response).to redirect_to("https://www.facebook.com/dialog/oauth")
    expect(Facebook::State.decrypt(seen)).to eq(attempt.id)
    expect(FacebookOauthAttempt.across_firms.find(attempt.id).handoff_used_at).to be_present

    get "/facebook/start", params: { ticket: }

    expect(response).to redirect_to("#{origin}/facebook/done?result=expired")
  end

  it "sends an expired ticket and a non-handoff attempt to the expired page" do
    expired = handoff("expired-ticket", handoff_expires_at: 1.minute.ago)
    get "/facebook/start", params: { ticket: "expired-ticket" }
    expect(response).to redirect_to("#{origin}/facebook/done?result=expired")
    expect(FacebookOauthAttempt.across_firms.find(expired.id).handoff_used_at).to be_nil

    plain = handoff("plain-ticket", handoff: false)
    get "/facebook/start", params: { ticket: "plain-ticket" }
    expect(response).to redirect_to("#{origin}/facebook/done?result=expired")
    expect(FacebookOauthAttempt.across_firms.find(plain.id).handoff_used_at).to be_nil
  end
end
