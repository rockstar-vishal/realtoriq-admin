# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trainings::Announce do
  let(:plan) { create(:plan) }

  # Firm traits rather than a status: a suspended firm also needs its reason,
  # and the factory's :suspended trait is what supplies it.
  def firm_with_broker(*firm_traits, **user_attributes)
    firm = create(:firm, *firm_traits)
    create(:subscription, firm:, plan:)
    [ firm, create(:user, firm:, **user_attributes) ]
  end

  def inbox_for(user)
    Notification.across_firms.where(user_id: user.id, kind: "training_published")
  end

  it "writes one inbox row for every active broker, in every firm" do
    _, first = firm_with_broker
    _, second = firm_with_broker
    training = create(:training, :active, title: "Closing Techniques")

    result = described_class.call(training:)

    expect(result.notified).to eq(2)
    expect(inbox_for(first).first.title).to eq("New training: Closing Techniques")
    expect(inbox_for(first).first.data).to include("page" => "skills-training", "item" => training.id)
    expect(inbox_for(second).count).to eq(1)
  end

  it "skips a suspended firm, whose brokers cannot sign in anyway" do
    _, suspended = firm_with_broker(:suspended)
    training = create(:training, :active)

    described_class.call(training:)

    expect(inbox_for(suspended).count).to eq(0)
  end

  it "skips a disabled broker" do
    _, disabled = firm_with_broker(status: :disabled)
    training = create(:training, :active)

    described_class.call(training:)

    expect(inbox_for(disabled).count).to eq(0)
  end

  it "leaves alone a broker who has turned notifications off" do
    _, quiet = firm_with_broker(notification_mode: "none")
    training = create(:training, :active)

    described_class.call(training:)

    expect(inbox_for(quiet).count).to eq(0)
  end

  it "is safe to run twice" do
    _, broker = firm_with_broker
    training = create(:training, :active)

    described_class.call(training:)
    second = described_class.call(training:)

    expect(second.notified).to eq(0)
    expect(inbox_for(broker).count).to eq(1)
  end

  it "says nothing about a training that is no longer active" do
    _, broker = firm_with_broker
    training = create(:training, :archived)

    expect(described_class.call(training:).notified).to eq(0)
    expect(inbox_for(broker).count).to eq(0)
  end
end
