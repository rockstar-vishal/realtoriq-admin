# frozen_string_literal: true

require "rails_helper"

RSpec.describe Facebook::ImportFailureDigestJob do
  include ActiveJob::TestHelper

  let(:firm) { create(:firm) }
  let(:owner) { create(:user, :super_admin, firm:, email: "owner@example.com") }
  let(:connection) { create(:facebook_connection, firm:, connected_by_user: owner) }
  let(:page) { create(:facebook_page, firm:, facebook_connection: connection, subscribed: true, status: "active") }

  def dead_import(message:, pending_at:, leadgen_id: nil, details: {})
    row = create(:facebook_lead_import, firm:, facebook_page: page, status: "dead", error_message: message,
      error_details: details, failure_alert_pending_at: pending_at)
    row.update_columns(leadgen_id:) if leadgen_id
    row
  end

  def run_digest
    perform_enqueued_jobs(only: Facebook::ImportFailureDigestFirmJob) do
      described_class.perform_now
    end
  end

  it "sends one email and one notice for a quiet burst, then nothing during the cooldown" do
    travel_to Time.zone.local(2026, 10, 5, 12, 0, 0) do
      3.times do |index|
        dead_import(message: "Pick a project or property for this form", pending_at: 2.minutes.ago,
          leadgen_id: "burst-#{index}")
      end

      expect { run_digest }.to change { ActionMailer::Base.deliveries.size }.by(1)
      mail = ActionMailer::Base.deliveries.last
      expect(mail.to).to eq([ "owner@example.com" ])
      expect(mail.subject).to eq("Facebook leads need attention")
      expect(mail.body.encoded).to include("3 Facebook leads")
      expect(mail.body.encoded).to include("Pick a project or property")
      expect(mail.body.encoded).to include("/settings/facebook")
      expect(Notification.across_firms.where(title: "Facebook leads need attention").count).to eq(1)
      expect(FacebookLeadImport.across_firms.where(firm_id: firm.id).where.not(failure_alert_pending_at: nil).count).to eq(0)

      waiting = dead_import(message: "Pick a project or property for this form", pending_at: 2.minutes.ago,
        leadgen_id: "later")
      expect { run_digest }.not_to change { ActionMailer::Base.deliveries.size }
      expect(FacebookLeadImport.across_firms.find(waiting.id).failure_alert_pending_at).to be_present
    end
  end

  it "sends the notice once when the super admin has no email" do
    travel_to Time.zone.local(2026, 10, 5, 12, 0, 0) do
      Current.set(firm:) { owner.update!(email: nil) }
      dead_import(message: "Pick a project or property for this form", pending_at: 2.minutes.ago)

      expect { run_digest }.not_to change { ActionMailer::Base.deliveries.size }
      expect(Notification.across_firms.where(title: "Facebook leads need attention").count).to eq(1)
      expect(FacebookLeadImport.across_firms.where(firm_id: firm.id).where.not(failure_alert_pending_at: nil).count).to eq(0)

      dead_import(message: "Pick a project or property for this form", pending_at: 2.minutes.ago, leadgen_id: "again")
      run_digest
      expect(Notification.across_firms.where(title: "Facebook leads need attention").count).to eq(1)
    end
  end

  it "waits until a fresh failure has been quiet" do
    travel_to Time.zone.local(2026, 10, 5, 12, 0, 0) do
      pending = dead_import(message: "Pick a project or property for this form", pending_at: 10.seconds.ago)
      expect { run_digest }.not_to change { ActionMailer::Base.deliveries.size }
      expect(FacebookLeadImport.across_firms.find(pending.id).failure_alert_pending_at).to be_present
    end
  end

  it "describes a fifth failure as five attempts" do
    travel_to Time.zone.local(2026, 10, 5, 12, 0, 0) do
      dead_import(message: "Facebook is busy. We'll try again.", pending_at: 2.minutes.ago,
        details: { "retry_count_at_failure" => 5 })
      run_digest
      expect(ActionMailer::Base.deliveries.last.body.encoded).to include("after 5 attempts")
    end
  end
end
