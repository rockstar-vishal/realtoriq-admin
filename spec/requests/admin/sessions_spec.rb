# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin sessions" do
  let!(:admin) { create(:admin_user, email: "ops@realtoriq.in") }

  describe "signing in" do
    it "lets a valid admin in" do
      post admin_session_path, params: { email: "ops@realtoriq.in", password: "correct-horse-battery" }

      expect(response).to redirect_to(admin_root_path)
      follow_redirect!
      expect(response.body).to include("Dashboard")
    end

    it "records the session with its origin, so access can be revoked" do
      expect { sign_in_admin(admin) }.to change { admin.admin_sessions.count }.by(1)

      expect(admin.admin_sessions.last.ip_address).to be_present
    end

    it "stamps the last login time" do
      expect { sign_in_admin(admin) }.to change { admin.reload.last_login_at }.from(nil)
    end

    it "is case-insensitive about the email" do
      post admin_session_path, params: { email: "OPS@RealtorIQ.in", password: "correct-horse-battery" }

      expect(response).to redirect_to(admin_root_path)
    end

    it "rejects a wrong password without saying which field was wrong" do
      post admin_session_path, params: { email: "ops@realtoriq.in", password: "nope" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("That email and password don&#39;t match.")
    end

    it "gives an unknown email the identical message, so accounts can't be enumerated" do
      post admin_session_path, params: { email: "stranger@example.com", password: "whatever" }

      expect(response.body).to include("That email and password don&#39;t match.")
    end

    it "refuses a deactivated admin" do
      deactivated = create(:admin_user, :deactivated)

      post admin_session_path, params: { email: deactivated.email, password: "correct-horse-battery" }

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "access control" do
    it "sends an anonymous visitor to sign-in" do
      get admin_root_path

      expect(response).to redirect_to(new_admin_session_path)
    end

    it "lets a signed-in admin through" do
      sign_in_admin(admin)
      get admin_root_path

      expect(response).to have_http_status(:ok)
    end

    it "locks out a session whose admin was deactivated mid-session" do
      sign_in_admin(admin)
      admin.update!(active: false)

      get admin_root_path

      expect(response).to redirect_to(new_admin_session_path)
    end

    it "rejects an expired session" do
      sign_in_admin(admin)
      admin.admin_sessions.last.update!(last_seen_at: (AdminSession::IDLE_TIMEOUT + 1.hour).ago)

      get admin_root_path

      expect(response).to redirect_to(new_admin_session_path)
    end

    it "destroys the expired session row rather than leaving it around" do
      sign_in_admin(admin)
      admin.admin_sessions.last.update!(last_seen_at: (AdminSession::IDLE_TIMEOUT + 1.hour).ago)

      expect { get admin_root_path }.to change { admin.admin_sessions.count }.to(0)
    end
  end

  describe "signing out" do
    it "ends the session and forgets the cookie" do
      sign_in_admin(admin)

      delete admin_session_path

      expect(response).to redirect_to(new_admin_session_path)
      expect(admin.admin_sessions.count).to eq(0)

      get admin_root_path
      expect(response).to redirect_to(new_admin_session_path)
    end
  end

  describe "tenant scoping inside the panel" do
    it "lifts the firm scope so cross-firm screens can work" do
      sign_in_admin(admin)
      create_list(:firm, 2)

      get admin_root_path

      # The dashboard counts every firm — with the bypass off it would show 0.
      expect(response.body).to match(/2/)
    end
  end
end
