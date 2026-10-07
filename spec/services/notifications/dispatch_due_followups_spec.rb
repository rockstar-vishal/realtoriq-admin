# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::DispatchDueFollowups do
  include ActiveSupport::Testing::TimeHelpers

  let(:firm) { create(:firm) }
  let(:assignee) { create(:user, firm:) }

  before do
    allow(Notifications::Vapid).to receive(:configured?).and_return(true)
    allow(Notifications::Vapid).to receive_messages(
      public_key: "test-public", private_key: "test-private", subject: "mailto:test@example.com"
    )
    allow(WebPush).to receive(:payload_send).and_return(true)
  end

  def due_lead(**attrs)
    create(:lead, firm:, assigned_user: assignee, next_action_at: 1.minute.ago, **attrs)
  end

  it "plants a watermark and does not push the existing backlog" do
    due_lead

    result = described_class.call

    expect(result.initialized).to be(true)
    expect(result.dispatched).to eq(0)
    expect(Notification.across_firms.count).to eq(0)
  end

  it "notifies the assignee once for a follow-up that becomes due, then not again" do
    described_class.call
    session, = AuthSession.start!(user: assignee, device: { device_id: "desk" })
    Current.set(firm:, user: assignee) do
      PushSubscription.create!(
        user: assignee, firm:, auth_session: session,
        endpoint: "https://push.example/assignee", p256dh: "p256", auth_key: "auth"
      )
    end
    lead = create(:lead, firm:, assigned_user: assignee, next_action_at: 30.seconds.from_now)

    travel 1.minute do
      result = described_class.call
      expect(result.dispatched).to eq(1)
      expect(assignee.notifications.count).to eq(1)
      expect(assignee.notifications.first.dedupe_key).to include(lead.id)
      expect(assignee.notifications.first.data).to include("page" => "leads", "item" => lead.id)
      expect(WebPush).to have_received(:payload_send).once
    end

    travel 2.minutes do
      expect(described_class.call.dispatched).to eq(0)
      expect(WebPush).to have_received(:payload_send).once
    end
  end

  it "skips unassigned leads, terminal leads, and brokers who opted out" do
    described_class.call
    create(:lead, firm:, assigned_user: nil, next_action_at: 30.seconds.from_now)
    create(:lead, firm:, assigned_user: assignee,
      lead_status: create(:lead_status, is_terminal: true),
      next_action_at: 30.seconds.from_now)
    quiet = create(:user, firm:, notification_mode: "none")
    create(:lead, firm:, assigned_user: quiet, next_action_at: 30.seconds.from_now)

    travel 1.minute do
      expect(described_class.call.dispatched).to eq(0)
      expect(Notification.across_firms.count).to eq(0)
    end
  end

  it "reaches a lead in another firm when no tenant is set" do
    described_class.call
    other_firm = create(:firm)
    other_user = create(:user, firm: other_firm)
    create(:lead, firm: other_firm, assigned_user: other_user, next_action_at: 30.seconds.from_now)
    Current.firm = nil

    travel 1.minute do
      expect(described_class.call.dispatched).to eq(1)
      expect(Notification.across_firms.where(user: other_user).count).to eq(1)
    end
  end
end
