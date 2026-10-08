# frozen_string_literal: true

require "rails_helper"

RSpec.describe Matches::DispatchSlot do
  include ActiveSupport::Testing::TimeHelpers

  let(:firm) { create(:firm) }
  let(:zone) { Time.find_zone("Asia/Kolkata") }

  before { allow(Matches::Slot).to receive(:for_firm).and_return(3) }

  it "enqueues the firm whose slot is this IST hour" do
    create(:subscription, firm:)
    travel_to zone.local(2026, 10, 8, 15, 5) do
      expect { described_class.call }.to have_enqueued_job(Matches::CurateFirmJob).with(firm.id)
    end
  end

  it "leaves a firm that was scanned within 11 hours" do
    create(:subscription, firm:)
    Current.set(firm:) do
      MatchDigest.create!(
        firm:, generated_at: Time.current, fingerprint: "abc",
        lead_items: [], listing_items: []
      )
    end

    travel_to zone.local(2026, 10, 8, 15, 5) do
      expect { described_class.call }.not_to have_enqueued_job(Matches::CurateFirmJob)
    end
  end

  it "skips a suspended firm and the review demo" do
    create(:firm, :suspended)
    create(:firm, review_demo: true)

    travel_to zone.local(2026, 10, 8, 15, 5) do
      expect { described_class.call }.not_to have_enqueued_job(Matches::CurateFirmJob)
    end
  end

  it "holds night finds until the 08:00 hour, then spreads them" do
    create(:subscription, firm:)
    Current.set(firm:) do
      MatchDigest.create!(
        firm:, generated_at: 6.hours.ago, fingerprint: "abc",
        lead_items: [ { "lead_id" => "x", "new_count" => 1, "match_ids" => [ "a" ] } ],
        listing_items: [], notification_pending: true
      )
    end

    travel_to zone.local(2026, 10, 8, 2, 10) do
      expect { described_class.call }.not_to have_enqueued_job(Matches::ReleaseDigestJob)
    end

    travel_to zone.local(2026, 10, 8, 8, 0) do
      expect { described_class.call }.to have_enqueued_job(Matches::ReleaseDigestJob).with(firm.id)
    end
  end

  it "catches up a firm that missed its hour" do
    missed = create(:firm)
    create(:subscription, firm: missed)
    allow(Matches::Slot).to receive(:for_firm) { |id| id == missed.id ? 1 : 3 }

    travel_to zone.local(2026, 10, 8, 15, 5) do
      Current.set(firm: missed) do
        MatchDigest.create!(
          firm: missed, generated_at: 14.hours.ago, fingerprint: "old",
          lead_items: [], listing_items: []
        )
      end
      described_class.call
      ids = ActiveJob::Base.queue_adapter.enqueued_jobs.map { |job| job[:args].first }
      expect(ids).to include(missed.id)
    end
  end

  it "waits for a firm's own hour when it has never been scanned" do
    waiting = create(:firm)
    create(:subscription, firm: waiting)
    create(:subscription, firm:)
    allow(Matches::Slot).to receive(:for_firm) { |id| id == waiting.id ? 1 : 3 }

    travel_to zone.local(2026, 10, 8, 15, 5) do
      described_class.call
      ids = ActiveJob::Base.queue_adapter.enqueued_jobs.map { |job| job[:args].first }
      expect(ids).to include(firm.id)
      expect(ids).not_to include(waiting.id)
    end
  end

  it "drops a lapsed firm's waiting ping" do
    create(:subscription, firm:, current_period_start: Date.new(2026, 8, 1), current_period_end: Date.new(2026, 10, 1))
    Current.set(firm:) do
      MatchDigest.create!(
        firm:, generated_at: 6.hours.ago, fingerprint: "abc", notification_pending: true,
        lead_items: [ { "lead_id" => "x", "new_count" => 1, "match_ids" => [ "a" ] } ],
        listing_items: []
      )
    end

    travel_to zone.local(2026, 10, 8, 8, 0) do
      expect { described_class.call }.not_to have_enqueued_job(Matches::ReleaseDigestJob)
    end
    expect(MatchDigest.across_firms.find_by!(firm:).notification_pending).to be(false)
  end

  it "keeps a firm in the same hour" do
    allow(Matches::Slot).to receive(:for_firm).and_call_original
    id = SecureRandom.uuid

    expect(Matches::Slot.for_firm(id)).to eq(Matches::Slot.for_firm(id))
    expect(Matches::Slot.for_firm(id)).to be_between(0, 11)
  end
end
