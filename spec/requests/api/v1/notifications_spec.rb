# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 notifications" do
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

  def session_for(target, device_id: "device-1")
    tokens_for(target, device_id:)
    AuthSession.across_firms.live.find_by!(user: target, device_id:)
  end

  def subscribe!(owner, session, endpoint: "https://push.example/#{SecureRandom.hex(8)}")
    Current.set(firm: owner.firm, user: owner) do
      PushSubscription.create!(
        user: owner, firm: owner.firm, auth_session: session,
        endpoint:, p256dh: "p256dh-key", auth_key: "auth-key"
      )
    end
  end

  before do
    allow(Notifications::Vapid).to receive(:configured?).and_return(true)
    allow(Notifications::Vapid).to receive_messages(
      public_key: "test-public", private_key: "test-private", subject: "mailto:test@example.com"
    )
    allow(WebPush).to receive(:payload_send).and_return(true)
  end

  describe "GET /notifications" do
    it "returns only the caller's inbox" do
      other = create(:user, firm: create(:firm))
      Current.set(firm:, user:) do
        user.notifications.create!(firm:, kind: "test", title: "Mine", body: "Hello", dedupe_key: "a")
      end
      Current.set(firm: other.firm, user: other) do
        other.notifications.create!(firm: other.firm, kind: "test", title: "Theirs", body: "Nope", dedupe_key: "b")
      end

      get "/api/v1/notifications", headers: auth_headers

      titles = response.parsed_body["notifications"].map { |row| row["title"] }
      expect(response).to have_http_status(:ok)
      expect(titles).to eq([ "Mine" ])
      expect(response.parsed_body.dig("meta", "unread_count")).to eq(1)
      expect(response.body).not_to include("p256dh")
    end

    it "is 404 for another firm's notification" do
      note = Current.set(firm:, user:) do
        user.notifications.create!(firm:, kind: "test", title: "Mine", body: "Hello", dedupe_key: "a")
      end
      outsider = create(:user, :super_admin, firm: create(:firm, :with_channels, status: :active))
      create(:subscription, firm: outsider.firm, plan:)

      patch "/api/v1/notifications/#{note.id}/read", headers: auth_headers(outsider, device_id: "device-outsider")

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "mark read" do
    it "marks one and then all" do
      Current.set(firm:, user:) do
        user.notifications.create!(firm:, kind: "test", title: "One", body: "A", dedupe_key: "a")
        user.notifications.create!(firm:, kind: "test", title: "Two", body: "B", dedupe_key: "b")
      end
      headers = auth_headers
      id = user.notifications.order(:created_at).first.id

      patch "/api/v1/notifications/#{id}/read", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("notification", "read_at")).to be_present

      post "/api/v1/notifications/mark_all_read", headers: headers
      expect(response.parsed_body["unread_count"]).to eq(0)
      expect(user.notifications.unread.count).to eq(0)
    end
  end

  describe "push subscription" do
    it "saves this session and does not echo the keys" do
      headers = auth_headers

      post "/api/v1/push_subscriptions",
        params: { endpoint: "https://push.example/device", p256dh: "p256", auth: "authkey" },
        headers: headers, as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body).to eq("push_subscription" => { "subscribed" => true })
      expect(response.body).not_to include("authkey")

      get "/api/v1/push_subscriptions", headers: headers
      expect(response.parsed_body.dig("push_subscription", "subscribed")).to be(true)
    end

    it "reassigns an endpoint when a different broker signs in on that browser" do
      endpoint = "https://push.example/shared-browser"
      first_session = session_for(user, device_id: "shared")
      subscribe!(user, first_session, endpoint:)

      other_firm = create(:firm, :with_channels, status: :active)
      create(:subscription, firm: other_firm, plan:)
      other = create(:user, :super_admin, firm: other_firm)
      headers = auth_headers(other, device_id: "other-device")

      post "/api/v1/push_subscriptions",
        params: { endpoint:, p256dh: "p256", auth: "authkey" },
        headers: headers, as: :json

      expect(response).to have_http_status(:created)
      expect(PushSubscription.across_firms.where(endpoint:).count).to eq(1)
      expect(PushSubscription.find_by_endpoint(endpoint).user_id).to eq(other.id)
    end

    it "deletes the subscription when the session is revoked" do
      session = session_for(user)
      subscribe!(user, session)
      expect(PushSubscription.across_firms.count).to eq(1)

      session.revoke!("signed_out")

      expect(PushSubscription.across_firms.count).to eq(0)
    end
  end

  describe "POST /notifications/test" do
    it "pushes only to the current session" do
      headers = auth_headers
      session = AuthSession.across_firms.live.find_by!(user:, device_id: "device-1")
      mine = subscribe!(user, session, endpoint: "https://push.example/mine")
      other_session, = AuthSession.start!(user:, device: { device_id: "device-2" })
      subscribe!(user, other_session, endpoint: "https://push.example/other")

      post "/api/v1/notifications/test", headers: headers

      expect(response).to have_http_status(:created)
      expect(WebPush).to have_received(:payload_send).with(hash_including(endpoint: mine.endpoint)).once
      expect(WebPush).not_to have_received(:payload_send).with(hash_including(endpoint: "https://push.example/other"))
    end

    it "fails clearly when this device has never enabled push" do
      post "/api/v1/notifications/test", headers: auth_headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("no_subscription")
      expect(WebPush).not_to have_received(:payload_send)
    end

    it "removes the subscription when the push service says it is gone" do
      headers = auth_headers
      session = AuthSession.across_firms.live.find_by!(user:, device_id: "device-1")
      subscribe!(user, session)
      gone = instance_double(Net::HTTPResponse, code: "410", body: "")
      allow(WebPush).to receive(:payload_send).and_raise(WebPush::ExpiredSubscription.new(gone, "push.example"))

      post "/api/v1/notifications/test", headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(PushSubscription.across_firms.count).to eq(0)
    end

    it "still sends when the broker's mode is none" do
      user.update!(notification_mode: "none")
      headers = auth_headers
      session = AuthSession.across_firms.live.find_by!(user:, device_id: "device-1")
      subscribe!(user, session)

      post "/api/v1/notifications/test", headers: headers

      expect(response).to have_http_status(:created)
    end
  end

  describe "Notifications::SendTest.to_user" do
    it "pushes to every device of the chosen broker and to nobody else" do
      session = session_for(user, device_id: "device-a")
      subscribe!(user, session, endpoint: "https://push.example/broker")
      stranger = create(:user, firm: create(:firm))
      stranger_session, = AuthSession.start!(user: stranger, device: { device_id: "device-s" })
      subscribe!(stranger, stranger_session, endpoint: "https://push.example/stranger")

      result = Notifications::SendTest.to_user(user)

      expect(result.ok?).to be(true)
      expect(result.accepted_count).to eq(1)
      expect(WebPush).to have_received(:payload_send).once
      expect(WebPush).to have_received(:payload_send).with(hash_including(endpoint: "https://push.example/broker"))
    end

    it "says so when that broker has no device" do
      result = Notifications::SendTest.to_user(user)

      expect(result.ok?).to be(false)
      expect(result.error_code).to eq("no_subscription")
      expect(WebPush).not_to have_received(:payload_send)
    end
  end
end
