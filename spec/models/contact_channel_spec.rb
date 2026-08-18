# frozen_string_literal: true

require "rails_helper"

RSpec.describe ContactChannel do
  let(:firm) { create(:firm) }

  before { Current.firm = firm }

  describe "normalisation" do
    it "downcases an email" do
      channel = create(:contact_channel, firm:, kind: :email, value: "  Ops@SethiRealty.IN ")
      expect(channel.value).to eq("ops@sethirealty.in")
    end

    it "converts a mobile to E.164" do
      channel = create(:contact_channel, firm:, kind: :mobile, value: "98201 44210")
      expect(channel.value).to eq("+919820144210")
    end
  end

  describe "validations" do
    it "rejects an email in the email channel that isn't one" do
      expect(build(:contact_channel, firm:, kind: :email, value: "nope")).not_to be_valid
    end

    it "rejects a non-number in the mobile channel" do
      expect(build(:contact_channel, firm:, kind: :mobile, value: "nope")).not_to be_valid
    end

    it "allows one channel of each kind per firm" do
      create(:contact_channel, :email, firm:)
      create(:contact_channel, :mobile, firm:)

      expect(build(:contact_channel, :whatsapp, firm:)).to be_valid
    end

    it "refuses a second channel of the same kind" do
      create(:contact_channel, :email, firm:)
      expect(build(:contact_channel, :email, firm:)).not_to be_valid
    end

    it "lets a different firm hold the same kind" do
      create(:contact_channel, :email, firm:)
      other_firm = create(:firm)
      Current.firm = other_firm

      expect(build(:contact_channel, :email, firm: other_firm)).to be_valid
    end
  end

  describe "WhatsApp as its own channel" do
    it "can carry a number different from the firm's stated mobile" do
      create(:contact_channel, firm:, kind: :mobile, value: "9820144210")
      whatsapp = create(:contact_channel, firm:, kind: :whatsapp, value: "9930071234")

      expect(whatsapp.value).to eq("+919930071234")
      expect(firm.contact_channels.count).to eq(2)
    end
  end

  describe "#mark_verified!" do
    let(:channel) { create(:contact_channel, :email, firm:) }

    it "records who verified it when done from the broker app" do
      super_admin = create(:user, :super_admin, firm:)
      channel.mark_verified!(by: super_admin)

      expect(channel).to be_verified
      expect(channel.verified_by_user).to eq(super_admin)
      expect(channel.verified_at).to be_present
    end

    it "carries no user when ops verified it from the admin panel" do
      channel.mark_verified!

      expect(channel).to be_verified
      expect(channel.verified_by_user).to be_nil
    end
  end

  describe "#reset_verification!" do
    it "returns the channel to unverified and forgets the history" do
      channel = create(:contact_channel, :email, :verified, firm:)
      channel.reset_verification!

      expect(channel).not_to be_verified
      expect(channel.verified_at).to be_nil
      expect(channel.last_code_sent_at).to be_nil
    end
  end

  describe "resend throttling" do
    let(:channel) { create(:contact_channel, :email, firm:) }

    it "is not throttled before any code is sent" do
      expect(channel).not_to be_resend_throttled
    end

    it "is throttled inside the cooldown" do
      channel.update!(last_code_sent_at: 10.seconds.ago)
      expect(channel).to be_resend_throttled
    end

    it "is clear once the cooldown has passed" do
      channel.update!(last_code_sent_at: 2.minutes.ago)
      expect(channel).not_to be_resend_throttled
    end
  end

  describe "#delivery_transport" do
    it "routes each kind to its carrier" do
      expect(build(:contact_channel, kind: :email).delivery_transport).to eq(:email)
      expect(build(:contact_channel, kind: :mobile).delivery_transport).to eq(:sms)
      expect(build(:contact_channel, kind: :whatsapp).delivery_transport).to eq(:whatsapp)
    end
  end
end
