# frozen_string_literal: true

require "rails_helper"

RSpec.describe Firm do
  describe "identifiers" do
    it "derives a slug from the name" do
      expect(create(:firm, name: "Sethi Realty").slug).to eq("sethi-realty")
    end

    it "disambiguates a slug that is already taken" do
      create(:firm, name: "Sethi Realty")
      expect(create(:firm, name: "Sethi Realty").slug).to eq("sethi-realty-2")
    end

    it "builds a code from the firm's state code" do
      city = create(:city, state: "Maharashtra")
      expect(create(:firm, city:).code).to match(/\ACP-MH-\d{5}\z/)
    end

    it "falls back to IN when the firm has no city yet" do
      expect(create(:firm, city: nil).code).to match(/\ACP-IN-\d{5}\z/)
    end

    it "upcases a hand-entered code" do
      expect(create(:firm, code: "cp-mh-04218").code).to eq("CP-MH-04218")
    end

    it "refuses a duplicate code" do
      create(:firm, code: "CP-MH-04218")
      expect(build(:firm, code: "CP-MH-04218")).not_to be_valid
    end
  end

  describe "validations" do
    it "rejects a malformed PAN" do
      expect(build(:firm, pan: "ABC123")).not_to be_valid
    end

    it "accepts a well-formed PAN, upcased" do
      firm = create(:firm, pan: "abcde1234f")
      expect(firm.pan).to eq("ABCDE1234F")
    end

    it "rejects a pincode that isn't six digits" do
      expect(build(:firm, pincode: "4102")).not_to be_valid
    end

    it "requires a reason when suspended" do
      expect(build(:firm, status: :suspended, suspension_reason: nil)).not_to be_valid
    end
  end

  describe "#suspend! and #activate!" do
    let(:firm) { create(:firm) }

    it "records the reason and timestamps the suspension" do
      firm.suspend!(reason: "Payment overdue")

      expect(firm).to be_suspended
      expect(firm.suspension_reason).to eq("Payment overdue")
      expect(firm.suspended_at).to be_present
    end

    it "clears the suspension when reactivated" do
      firm.suspend!(reason: "Payment overdue")
      firm.activate!

      expect(firm).to be_active
      expect(firm.suspended_at).to be_nil
      expect(firm.suspension_reason).to be_nil
      expect(firm.activated_at).to be_present
    end

    it "writes an audit event for each transition" do
      firm.suspend!(reason: "Payment overdue")
      firm.activate!

      expect(AuditEvent.where(subject: firm).pluck(:action))
        .to contain_exactly("firm.suspended", "firm.activated")
    end
  end

  describe "#fully_verified?" do
    let(:firm) { create(:firm) }

    it "is false until all three channels are verified" do
      Current.firm = firm
      create(:contact_channel, :email, :verified, firm:)
      create(:contact_channel, :mobile, :verified, firm:)
      create(:contact_channel, :whatsapp, firm:)

      expect(firm.reload).not_to be_fully_verified
    end

    it "is true once email, mobile and WhatsApp are all verified" do
      Current.firm = firm
      create(:contact_channel, :email, :verified, firm:)
      create(:contact_channel, :mobile, :verified, firm:)
      create(:contact_channel, :whatsapp, :verified, firm:)

      expect(firm.reload).to be_fully_verified
    end
  end

  describe ".search" do
    it "matches on the firm's own fields and on its users' contact details" do
      target = create(:firm, name: "Sethi Realty")
      create(:user, firm: target, mobile: "+919820144210")
      create(:firm, name: "Kapoor Estates")

      expect(described_class.search("Sethi").pluck(:id)).to eq([ target.id ])
      expect(described_class.search("9820144210").pluck(:id)).to eq([ target.id ])
    end

    it "returns everything for a blank term" do
      create_list(:firm, 2)
      expect(described_class.search("").count).to eq(2)
    end
  end
end
