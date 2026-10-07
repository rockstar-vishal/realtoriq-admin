# frozen_string_literal: true

require "rails_helper"

RSpec.describe Facebook::OauthService do
  let(:oauth) { instance_double(Koala::Facebook::OAuth) }

  before do
    allow(Facebook::Credentials).to receive(:fetch!).and_call_original
    allow(Facebook::Credentials).to receive(:[]).and_call_original
    allow(Rails.application.credentials).to receive(:dig).and_call_original
    allow(Rails.application.credentials).to receive(:dig).with(:facebook, :app_id).and_return("app-id")
    allow(Rails.application.credentials).to receive(:dig).with(:facebook, :app_secret).and_return("app-secret")
    allow(Rails.application.credentials).to receive(:dig).with(:facebook, :configuration_id).and_return("config-1")
    allow(Rails.application.credentials).to receive(:dig).with(:facebook, :access_token_kind).and_return("system_user")
    allow(Koala::Facebook::OAuth).to receive(:new).and_return(oauth)
  end

  it "builds a system-user login url with response_type=code and the configuration id" do
    expect(oauth).to receive(:url_for_oauth_code).with(
      hash_including(state: "signed", config_id: "config-1", response_type: "code",
        override_default_response_type: "true")
    ).and_return("https://www.facebook.com/dialog/oauth")

    expect(described_class.new.authorization_url(state: "signed")).to eq("https://www.facebook.com/dialog/oauth")
  end

  it "refuses a system-user token that expires in under a day" do
    allow(oauth).to receive(:get_access_token_info).and_return(
      "access_token" => "short", "expires_in" => 3_600
    )

    expect { described_class.new.exchange_code(code: "abc") }
      .to raise_error(Facebook::Errors::ShortLivedTokenError)
  end
end
