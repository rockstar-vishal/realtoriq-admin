# frozen_string_literal: true

require "rails_helper"

RSpec.describe User do
  let(:firm) { create(:firm) }

  describe "mobile normalisation" do
    it "converts a bare 10-digit number to E.164" do
      expect(create(:user, firm:, mobile: "9820144210").mobile).to eq("+919820144210")
    end

    it "strips spaces and punctuation" do
      expect(create(:user, firm:, mobile: "+91 98201-44210").mobile).to eq("+919820144210")
    end

    it "drops the domestic trunk prefix" do
      expect(create(:user, firm:, mobile: "09820144210").mobile).to eq("+919820144210")
    end

    it "rejects something that isn't a phone number" do
      expect(build(:user, firm:, mobile: "not-a-number")).not_to be_valid
    end
  end

  describe "mobile uniqueness" do
    it "is global, not per firm — the sign-in screen has nothing else to scope by" do
      create(:user, firm:, mobile: "9820144210")
      other = build(:user, firm: create(:firm), mobile: "9820144210")

      expect(other).not_to be_valid
      expect(other.errors[:mobile]).to be_present
    end

    it "treats differently-formatted versions of one number as the same" do
      create(:user, firm:, mobile: "+919820144210")
      expect(build(:user, firm:, mobile: "098201 44210")).not_to be_valid
    end
  end

  describe "one super_admin per firm" do
    it "refuses a second super_admin at the database level" do
      create(:user, :super_admin, firm:)

      expect { create(:user, :super_admin, firm:) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "allows a super_admin in each of two firms" do
      create(:user, :super_admin, firm:)
      expect { create(:user, :super_admin, firm: create(:firm)) }.not_to raise_error
    end

    it "allows many managers and agents in one firm" do
      create_list(:user, 3, :manager, firm:)
      expect(described_class.across_firms.where(firm:).count).to eq(3)
    end
  end

  describe "OTP lockout" do
    let(:user) { create(:user, firm:) }

    it "locks sign-in after three failed attempts" do
      3.times { user.register_failed_otp_attempt! }

      expect(user).to be_locked_out
      expect(user.otp_locked_until).to be_within(1.minute).of(30.minutes.from_now)
    end

    it "does not lock before the third failure" do
      2.times { user.register_failed_otp_attempt! }
      expect(user).not_to be_locked_out
    end

    it "resets the counter when the lock is applied, so the next window is clean" do
      3.times { user.register_failed_otp_attempt! }
      expect(user.failed_otp_attempts).to eq(0)
    end

    it "treats an expired lock as unlocked" do
      user.update!(otp_locked_until: 1.minute.ago)
      expect(user).not_to be_locked_out
    end

    it "clears the lock on a successful sign-in" do
      3.times { user.register_failed_otp_attempt! }
      user.clear_otp_lockout!

      expect(user).not_to be_locked_out
    end
  end

  describe ".find_for_sign_in" do
    it "resolves a user across firms without a tenant being set" do
      user = create(:user, firm:, mobile: "9820144210")
      Current.firm = nil

      expect(described_class.find_for_sign_in(mobile: "098201 44210")).to eq(user)
    end

    it "returns nil for an unknown number" do
      expect(described_class.find_for_sign_in(mobile: "9000000000")).to be_nil
    end
  end

  describe "#can_manage_firm_settings?" do
    it "is true only for the super_admin" do
      expect(build(:user, :super_admin).can_manage_firm_settings?).to be(true)
      expect(build(:user, :manager).can_manage_firm_settings?).to be(false)
      expect(build(:user, role: :agent).can_manage_firm_settings?).to be(false)
    end
  end
end
