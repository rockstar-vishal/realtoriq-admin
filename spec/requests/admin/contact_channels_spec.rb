# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin contact channel verification" do
  before { sign_in_admin }

  let(:firm) { create(:firm, :with_channels) }
  let(:mobile) { firm.contact_channels.find_by(kind: :mobile) }
  let(:email) { firm.contact_channels.find_by(kind: :email) }

  describe "sending a code" do
    it "issues a code and hands it to the right transport" do
      post send_code_admin_firm_contact_channel_path(firm, mobile)

      expect(deliverer.last.transport).to eq(:sms)
      expect(deliverer.last.destination).to eq(mobile.value)
      expect(deliverer.last.code).to match(/\A\d{6}\z/)
    end

    it "routes the email channel through email, not SMS" do
      post send_code_admin_firm_contact_channel_path(firm, email)

      expect(deliverer.last.transport).to eq(:email)
    end

    it "moves the channel to pending" do
      post send_code_admin_firm_contact_channel_path(firm, mobile)

      expect(mobile.reload).to be_verification_pending
      expect(mobile.last_code_sent_at).to be_present
    end

    it "refuses a second code inside the cooldown" do
      post send_code_admin_firm_contact_channel_path(firm, mobile)

      expect {
        post send_code_admin_firm_contact_channel_path(firm, mobile)
      }.not_to change(OneTimeCode, :count)
    end

    it "allows another code once the cooldown has passed" do
      post send_code_admin_firm_contact_channel_path(firm, mobile)
      mobile.update!(last_code_sent_at: 5.minutes.ago)

      expect {
        post send_code_admin_firm_contact_channel_path(firm, mobile)
      }.to change(OneTimeCode, :count).by(1)
    end

    it "reports a provider outage without leaving the channel pending" do
      Notifications::Deliverer.current = SpyDeliverer::Failing.new

      post send_code_admin_firm_contact_channel_path(firm, mobile)

      expect(mobile.reload).to be_verification_unverified
      expect(flash[:alert]).to be_present
    end

    it "replaces only that channel's row" do
      post send_code_admin_firm_contact_channel_path(firm, mobile),
        headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      expect(response.body).to include("contact_channel_#{mobile.id}")
      expect(response.body).not_to include("contact_channel_#{email.id}")
    end
  end

  describe "marking verified by ops" do
    it "verifies without recording a broker user" do
      # Ops confirming out of band — they phoned the firm. Distinct from the
      # firm proving it itself, which is why verified_by_user stays null.
      patch mark_verified_admin_firm_contact_channel_path(firm, mobile)

      expect(mobile.reload).to be_verified
      expect(mobile.verified_by_user).to be_nil
    end

    it "writes an audit event naming the admin" do
      patch mark_verified_admin_firm_contact_channel_path(firm, mobile)

      event = AuditEvent.find_by(action: "channel.verified_by_admin")
      expect(event.actor).to be_an(AdminUser)
      expect(event.firm).to eq(firm)
    end
  end

  describe "resetting" do
    it "clears a verified channel" do
      mobile.mark_verified!

      patch reset_admin_firm_contact_channel_path(firm, mobile)

      expect(mobile.reload).not_to be_verified
      expect(mobile.verified_at).to be_nil
    end
  end

  describe "scoping" do
    it "will not act on a channel belonging to another firm" do
      other = create(:firm, :with_channels)
      foreign = other.contact_channels.first

      patch mark_verified_admin_firm_contact_channel_path(firm, foreign)

      # The channel is looked up through this firm's association, so an id from
      # elsewhere resolves to nothing. Rails renders that as 404 rather than
      # raising, since test env rescues RecordNotFound like production does.
      expect(response).to have_http_status(:not_found)
      expect(foreign.reload).not_to be_verified
    end
  end
end
