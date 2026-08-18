# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 auth" do
  let(:plan) { create(:plan, max_devices: 3) }
  let(:firm) { create(:firm, status: :active) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:user) { create(:user, :super_admin, firm:, mobile: "+919820144210") }

  def request_code(mobile = "9820144210")
    post "/api/v1/auth/otp", params: { mobile: }, as: :json
    response.parsed_body
  end

  def sign_in(device: {})
    body = request_code
    post "/api/v1/auth/verify",
      params: { request_id: body["request_id"], code: deliverer.last.code, device: }, as: :json
    response.parsed_body
  end

  describe "POST /auth/otp" do
    it "sends a code to the user's mobile" do
      body = request_code

      expect(response).to have_http_status(:ok)
      expect(deliverer.last.transport).to eq(:sms)
      expect(deliverer.last.destination).to eq("+919820144210")
      expect(body["expires_in"]).to be_positive
    end

    it "masks the destination in the response, for the OTP screen's copy" do
      # Matches the design's "Six digits sent to +91 98201 44xxx".
      expect(request_code["sent_to"]).to eq("+919820144xxx")
    end

    it "accepts any format of the same number" do
      request_code("098201 44210")

      expect(response).to have_http_status(:ok)
    end

    it "returns not_registered for an unknown number" do
      request_code("9000000000")

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig("error", "code")).to eq("not_registered")
    end

    it "refuses a disabled user" do
      user.update!(status: :disabled)

      request_code

      expect(response.parsed_body.dig("error", "code")).to eq("account_disabled")
    end

    it "refuses while the user is locked out" do
      user.update!(otp_locked_until: 20.minutes.from_now)

      request_code

      expect(response).to have_http_status(:too_many_requests)
      expect(response.parsed_body.dig("error", "code")).to eq("otp_locked")
    end

    it "reports a delivery failure instead of pretending it sent" do
      Notifications::Deliverer.current = SpyDeliverer::Failing.new

      request_code

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body.dig("error", "code")).to eq("delivery_failed")
    end
  end

  describe "POST /auth/verify" do
    it "returns tokens and the bootstrap payload" do
      body = sign_in

      expect(response).to have_http_status(:ok)
      expect(body["access_token"]).to be_present
      expect(body["refresh_token"]).to be_present
      expect(body.dig("user", "role")).to eq("super_admin")
      expect(body.dig("firm", "code")).to eq(firm.code)
      expect(body.dig("subscription", "entitled")).to be(true)
    end

    it "rejects a wrong code and counts down the attempts" do
      requested = request_code

      post "/api/v1/auth/verify",
        params: { request_id: requested["request_id"], code: "000000" }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body.dig("error", "details", "attempts_left")).to eq(2)
    end

    it "locks sign-in after three wrong codes" do
      requested = request_code

      3.times do
        post "/api/v1/auth/verify",
          params: { request_id: requested["request_id"], code: "000000" }, as: :json
      end

      expect(user.reload).to be_locked_out
    end

    it "will not let a code be replayed" do
      body = request_code
      code = deliverer.last.code

      2.times do
        post "/api/v1/auth/verify", params: { request_id: body["request_id"], code: }, as: :json
      end

      expect(response).to have_http_status(:unauthorized)
    end

    it "clears an earlier lockout on success" do
      user.update!(failed_otp_attempts: 2)

      sign_in

      expect(user.reload.failed_otp_attempts).to eq(0)
    end

    it "refuses a suspended firm only after the code is proven" do
      firm.suspend!(reason: "Payment overdue")

      sign_in

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("account_suspended")
    end
  end

  describe "device sessions" do
    it "records the device against the session" do
      sign_in(device: { device_id: "abc-123", device_name: "Tanmay's iPhone", platform: "ios" })

      session = user.auth_sessions.sole
      expect(session.device_name).to eq("Tanmay's iPhone")
      expect(session.device_id).to eq("abc-123")
    end

    it "reclaims the slot when the same device signs in again" do
      2.times { sign_in(device: { device_id: "abc-123" }) }

      expect(user.auth_sessions.live.count).to eq(1)
    end

    it "evicts the oldest session past the plan's device limit" do
      # The design has a "device limit reached" wall, but blocking the phone
      # someone just bought is a support ticket — so the newest device wins and
      # the oldest is signed out.
      4.times { |i| sign_in(device: { device_id: "device-#{i}" }) }

      live = user.auth_sessions.live
      expect(live.count).to eq(plan.max_devices)
      expect(live.pluck(:device_id)).not_to include("device-0")
      expect(user.auth_sessions.find_by(device_id: "device-0").revoked_reason).to eq("device_limit")
    end
  end

  describe "POST /auth/refresh" do
    it "issues a new access token and rotates the refresh token" do
      original = sign_in["refresh_token"]

      post "/api/v1/auth/refresh", params: { refresh_token: original }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["refresh_token"]).not_to eq(original)
    end

    it "refuses the old refresh token once rotated" do
      original = sign_in["refresh_token"]
      post "/api/v1/auth/refresh", params: { refresh_token: original }, as: :json

      post "/api/v1/auth/refresh", params: { refresh_token: original }, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses a revoked session" do
      token = sign_in["refresh_token"]
      user.auth_sessions.live.sole.revoke!

      post "/api/v1/auth/refresh", params: { refresh_token: token }, as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "DELETE /auth/session" do
    it "revokes the session" do
      token = sign_in["refresh_token"]

      delete "/api/v1/auth/session", params: { refresh_token: token }, as: :json

      expect(response).to have_http_status(:no_content)
      expect(user.auth_sessions.live.count).to eq(0)
    end

    it "says nothing about whether an unknown token was live" do
      delete "/api/v1/auth/session", params: { refresh_token: "made-up" }, as: :json

      expect(response).to have_http_status(:no_content)
    end
  end
end
