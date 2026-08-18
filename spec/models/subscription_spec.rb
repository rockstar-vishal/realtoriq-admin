# frozen_string_literal: true

require "rails_helper"

RSpec.describe Subscription do
  let(:firm) { create(:firm) }
  let(:plan) { create(:plan, price: 2_499, interval: "month") }

  before { Current.firm = firm }

  describe "#entitled?" do
    it "is true for a live subscription inside its period" do
      expect(create(:subscription, firm:, plan:)).to be_entitled
    end

    it "is false once the period has run out, whatever the stored status says" do
      # The status column is set by hand by ops. If nobody gets round to marking
      # a firm lapsed, the date still has to cut them off.
      subscription = create(:subscription, :expired, firm:, plan:, status: :active)

      expect(subscription).not_to be_entitled
    end

    it "is false for a cancelled subscription" do
      expect(create(:subscription, :cancelled, firm:, plan:)).not_to be_entitled
    end

    it "counts the final day of the period as still entitled" do
      subscription = create(:subscription, firm:, plan:, current_period_end: Date.current)

      expect(subscription).to be_entitled
    end
  end

  describe "one live subscription per firm" do
    it "is enforced by the database" do
      create(:subscription, firm:, plan:)

      expect { create(:subscription, firm:, plan:) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "allows a live one alongside cancelled history" do
      create(:subscription, :cancelled, firm:, plan:)

      expect { create(:subscription, firm:, plan:) }.not_to raise_error
    end
  end

  describe "#renew!" do
    it "extends from the end of the current period" do
      subscription = create(:subscription, firm:, plan:,
        current_period_start: Date.current, current_period_end: Date.current + 10.days)

      subscription.renew!

      expect(subscription.current_period_start).to eq(Date.current + 11.days)
      expect(subscription.current_period_end).to eq(Date.current + 11.days + 1.month - 1.day)
    end

    it "restarts from today when the period already lapsed" do
      # Renewing a firm that lapsed two months ago shouldn't hand them a period
      # that is still in the past.
      subscription = create(:subscription, :expired, firm:, plan:)

      subscription.renew!

      expect(subscription.current_period_start).to eq(Date.current)
      expect(subscription).to be_entitled
    end

    it "re-snapshots the plan's current price" do
      subscription = create(:subscription, firm:, plan:, amount: 999)
      plan.update!(price: 3_499)

      subscription.renew!

      expect(subscription.amount).to eq(3_499)
    end
  end

  describe ".switch_plan!" do
    it "supersedes the live subscription instead of overwriting it" do
      old = create(:subscription, firm:, plan:)
      premium = create(:plan, name: "Premium", price: 4_999)

      created = described_class.switch_plan!(firm:, plan: premium)

      expect(old.reload).to be_cancelled
      expect(created).to be_entitled
      expect(firm.subscriptions.count).to eq(2)
    end

    it "snapshots the new plan's price" do
      premium = create(:plan, price: 4_999)

      expect(described_class.switch_plan!(firm:, plan: premium).amount).to eq(4_999)
    end
  end

  describe ".expiring_within" do
    it "finds live subscriptions ending inside the window" do
      soon = create(:subscription, firm:, plan:, current_period_end: 5.days.from_now.to_date)
      create(:subscription, firm: create(:firm), plan:, current_period_end: 90.days.from_now.to_date)

      expect(described_class.across_firms.expiring_within(30).pluck(:id)).to eq([ soon.id ])
    end

    it "ignores already-cancelled ones" do
      create(:subscription, :cancelled, firm:, plan:, current_period_end: 5.days.from_now.to_date)

      expect(described_class.across_firms.expiring_within(30).count).to eq(0)
    end
  end

  describe "validations" do
    it "rejects a period that ends before it starts" do
      subscription = build(:subscription, firm:, plan:,
        current_period_start: Date.current, current_period_end: Date.current - 1.day)

      expect(subscription).not_to be_valid
    end
  end
end
