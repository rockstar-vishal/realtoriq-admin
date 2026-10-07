# frozen_string_literal: true

require "rails_helper"

RSpec.describe Facebook::ImportSweeperJob do
  let(:firm) { create(:firm) }
  let(:page) { create(:facebook_page, firm:, subscribed: true, status: "active") }

  def import_with(**attrs)
    row = create(:facebook_lead_import, firm:, facebook_page: page)
    Current.set(firm:) { row.update_columns(attrs) }
    row
  end

  it "reenqueues stale pending and failed imports and resets a stuck processing row" do
    pending = import_with(status: "pending", created_at: 11.minutes.ago, next_attempt_at: nil)
    fresh = import_with(status: "pending", created_at: 1.minute.ago, next_attempt_at: nil)
    failed = import_with(status: "failed", next_attempt_at: 11.minutes.ago)
    stuck = import_with(status: "processing", processing_started_at: 16.minutes.ago)

    described_class.perform_now

    expect(Facebook::ProcessLeadJob).to have_been_enqueued.with(firm.id, pending.id)
    expect(Facebook::ProcessLeadJob).to have_been_enqueued.with(firm.id, failed.id)
    expect(Facebook::ProcessLeadJob).to have_been_enqueued.with(firm.id, stuck.id)
    expect(Facebook::ProcessLeadJob).not_to have_been_enqueued.with(firm.id, fresh.id)
    expect(FacebookLeadImport.across_firms.find(stuck.id).status).to eq("pending")

    described_class.perform_now
    expect(Facebook::ProcessLeadJob).to have_been_enqueued.with(firm.id, pending.id).once
    expect(Facebook::ProcessLeadJob).to have_been_enqueued.with(firm.id, failed.id).once
  end
end
