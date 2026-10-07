# frozen_string_literal: true

require "rails_helper"

RSpec.describe Facebook::TokenHealthCheckJob do
  include ActiveJob::TestHelper

  let(:firm) { create(:firm) }
  let(:owner) { create(:user, :super_admin, firm:, email: "owner@example.com") }
  let(:connection) do
    create(:facebook_connection, firm:, connected_by_user: owner, token_kind: "system_access", status: "active")
  end
  let(:client) { instance_double(Facebook::GraphApiClient) }

  before do
    connection
    oauth = instance_double(Facebook::OauthService, app_access_token: "app|secret")
    allow(Facebook::OauthService).to receive(:new).and_return(oauth)
    allow(Facebook::GraphApiClient).to receive(:new).and_return(client)
    allow(client).to receive(:debug_token).and_return("is_valid" => false)
  end

  it "alerts once when a system-user token is no longer valid" do
    perform_enqueued_jobs(only: [ Facebook::TokenHealthCheckFirmJob, Facebook::TokenInvalidAlertJob ]) do
      described_class.perform_now
    end

    expect(FacebookConnection.across_firms.find(connection.id)).to be_connection_invalid
    expect(ActionMailer::Base.deliveries.size).to eq(1)
    expect(ActionMailer::Base.deliveries.last.subject).to eq("Reconnect Facebook to keep receiving leads")
    expect(ActionMailer::Base.deliveries.last.body.encoded).to include("/settings/facebook")
    expect(Notification.across_firms.where(title: "Facebook needs to be connected again").count).to eq(1)

    expect {
      perform_enqueued_jobs(only: [ Facebook::TokenHealthCheckFirmJob, Facebook::TokenInvalidAlertJob ]) do
        described_class.perform_now
      end
    }.not_to change { ActionMailer::Base.deliveries.size }
    expect(Notification.across_firms.where(title: "Facebook needs to be connected again").count).to eq(1)
  end

  it "stops one Page when only that Page token is invalid" do
    good = create(:facebook_page, firm:, facebook_connection: connection, page_access_token: "good-page",
      subscribed: true, status: "active")
    bad = create(:facebook_page, firm:, facebook_connection: connection, page_access_token: "bad-page",
      subscribed: true, status: "active")
    allow(client).to receive(:debug_token) { |input_token:| { "is_valid" => input_token != "bad-page" } }
    allow(client).to receive(:verify_token).and_return("id" => "system-user")

    perform_enqueued_jobs(only: [ Facebook::TokenHealthCheckFirmJob, Facebook::PageAttentionJob ]) do
      described_class.perform_now
    end

    expect(connection.reload).to be_connection_active
    expect(bad.reload).to be_page_error
    expect(good.reload).to be_page_active
    expect(Notification.across_firms.where(title: "A Facebook Page needs attention").count).to eq(1)
    expect(ActionMailer::Base.deliveries.last.subject).to eq("A Facebook Page needs attention")
  end

  it "leaves the login unchanged when a Page token cannot be read" do
    page = create(:facebook_page, firm:, facebook_connection: connection, page_access_token: "opaque",
      subscribed: true, status: "active")
    allow(client).to receive(:debug_token).and_return({})
    allow(client).to receive(:verify_token).and_return("id" => "system-user")

    expect(Facebook::TokenManager.health_check!(connection)).to be false
    expect(connection.reload).to be_connection_active
    expect(page.reload).to be_page_active
  end
end
