# frozen_string_literal: true

require "rails_helper"

RSpec.describe Matches::Rebaseline do
  include ActiveSupport::Testing::TimeHelpers

  let(:firm) { create(:firm) }
  let!(:subscription) { create(:subscription, firm:) }
  let!(:super_admin) { create(:user, :super_admin, firm:) }
  let(:city) { create(:city) }
  let(:locality) { create(:locality, city:) }
  let(:typology) { create(:typology, name: "2 BHK", code: "2_bhk") }
  let(:ready) { create(:property_type, name: "Ready possession") }
  let(:status) { create(:lead_status, :new_lead) }

  before { Current.firm = firm }
  after { Current.reset }

  it "locks each eligible firm and rewrites the digest without notifying" do
    create(:property, firm:, typology:, price: 10_000_000, city:, locality:)
    create(:lead, firm:, lead_status: status, budget_max: 10_000_000, transaction_type: "sale", property_type: ready).tap do |lead|
      lead.typologies << typology
      lead.localities << locality
    end

    held = false
    allow(Matches::CurateFirm).to receive(:call).and_wrap_original do |method, **kwargs|
      expect(kwargs).to include(firm:, announce: false)
      held = Matches::ScanLock.held?(firm)
      method.call(**kwargs)
    end

    travel_to Time.find_zone("Asia/Kolkata").local(2026, 10, 8, 11) do
      described_class.call
    end

    digest = MatchDigest.find_by!(firm:)
    expect(held).to be(true)
    expect(Matches::ScanLock.held?(firm)).to be(false)
    expect(digest.notification_pending).to be(false)
    expect(digest.notified_fingerprint).to eq(digest.fingerprint)
    expect(digest.lead_items).not_to be_empty
    expect(Notification.across_firms.where(kind: "match_digest")).to be_empty
    expect(super_admin).to be_present
    expect(subscription).to be_present
  end
end
