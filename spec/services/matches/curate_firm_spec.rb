# frozen_string_literal: true

require "rails_helper"

RSpec.describe Matches::CurateFirm do
  include ActiveSupport::Testing::TimeHelpers

  let(:firm) { create(:firm) }
  let(:other_firm) { create(:firm, name: "Mehta Estates") }
  let!(:subscription) { create(:subscription, firm:) }
  let!(:super_admin) { create(:user, :super_admin, firm:) }
  let(:city) { create(:city) }
  let(:locality) { create(:locality, city:, name: "Kharghar") }
  let(:two_bhk) { create(:typology, name: "2 BHK") }
  let(:ready_type) { create(:property_type, name: "Ready possession") }
  let(:live_status) { create(:lead_status, :new_lead) }
  let(:dead_status) { create(:lead_status, :dead) }
  let(:zone) { Time.find_zone("Asia/Kolkata") }

  before { Current.firm = firm }
  after { Current.reset }

  def ready_lead(**attrs)
    create(:lead, firm:, lead_status: live_status, budget_max: 10_000_000,
      transaction_type: "sale", property_type: ready_type, **attrs).tap do |lead|
      lead.typologies << two_bhk
      lead.localities << locality
    end
  end

  def own_project(name: "Own Vista")
    create(:project, firm:, city:, locality:, name:, starting_budget: 10_000_000,
      possession_on: Date.new(2026, 11, 1), possession_label: nil).tap do |project|
      create(:project_typology, project:, typology: two_bhk, starting_price: 10_000_000)
    end
  end

  def own_property(price: 10_000_000)
    create(:property, firm:, typology: two_bhk, price:,
      building: create(:building, firm:, city:, locality:))
  end

  def match_ids_for(lead)
    Inventory::MatchInventory.new(lead:).call.map { |row| "#{row[:kind]}:#{row[:id]}" }
  end

  def digest_lead(digest, lead)
    digest.lead_items.find { |item| item["lead_id"] == lead.id }
  end

  it "stores the same unlinked matches the live matcher would, and tells the super admin" do
    travel_to zone.local(2026, 10, 8, 11) do
      project = own_project
      listing = own_property
      mapped = own_property
      shared = create(:property, firm: other_firm, typology: two_bhk, price: 10_000_000, listed_on_marketplace: true,
        building: create(:building, firm: other_firm, city:, locality:))
      lead = ready_lead(name: "Asha")
      dead = ready_lead(lead_status: dead_status, dead_reason: "Gone quiet", name: "Quiet")
      skipped = ready_lead(unqualified: true, name: "Skip")
      linked = ready_lead(name: "Linked")
      linked.lead_properties.create!(property: mapped, firm:)

      digest = described_class.call(firm:)

      expect(digest_lead(digest, lead)["match_ids"]).to eq(match_ids_for(lead))
      expect(digest_lead(digest, lead)["match_ids"]).to include("property:#{shared.id}")
      property_leads = Inventory::MatchLeads.new(user: super_admin, property: listing).call
        .reject { |row| row[:mapped] }
        .map { |row| row[:id] }
      expect(digest.listing_items.find { |item| item["id"] == listing.id }["match_ids"]).to eq(property_leads)
      expect(digest_lead(digest, dead)["match_ids"]).to eq(match_ids_for(dead))
      expect(digest_lead(digest, dead)["dead"]).to be(true)
      expect(digest_lead(digest, lead)["dead"]).to be(false)
      expect(digest_lead(digest, skipped)).to be_nil
      expect(digest_lead(digest, linked)["match_ids"]).not_to include("property:#{mapped.id}")
      expect(digest_lead(digest, linked)["match_ids"]).to include("project:#{project.id}", "property:#{listing.id}")
      expect(digest.listing_items.map { |item| item["id"] }).to include(project.id, listing.id)
      expect(digest.listing_items.find { |item| item["id"] == listing.id }["listing_for"]).to eq("sale")
      expect(digest.listing_items.find { |item| item["id"] == project.id }).not_to have_key("listing_for")
      expect(digest.notification_pending).to be(false)

      note = Notification.across_firms.find_by!(kind: "match_digest", user: super_admin)
      expect(note.data).to eq("page" => "matches")
      expect(note.title).to eq("New matches are ready")
      expect(note.body).to include("leads have new options")
      expect(note.body).not_to include("Asha")
    end
  end

  it "does not ping again when the list is unchanged" do
    travel_to zone.local(2026, 10, 8, 11) do
      own_property
      ready_lead(name: "Asha")
      described_class.call(firm:)

      expect { described_class.call(firm:) }.not_to change { Notification.across_firms.count }
      expect(MatchDigest.find_by(firm:).lead_items.first["new_count"]).to eq(0)
    end
  end

  it "saves a night find without pinging, and the morning release pings once" do
    own_property
    ready_lead(name: "Asha")

    travel_to zone.local(2026, 10, 8, 2) do
      digest = described_class.call(firm:)
      expect(digest.notification_pending).to be(true)
      expect(Notification.across_firms.count).to eq(0)
    end

    Matches::ReleaseDigest.call(firm:)
    expect(Notification.across_firms.where(kind: "match_digest").count).to eq(1)
    expect(MatchDigest.find_by(firm:).notification_pending).to be(false)

    Matches::ReleaseDigest.call(firm:)
    expect(Notification.across_firms.where(kind: "match_digest").count).to eq(1)
  end

  it "does not queue another ping when the morning release lands while the next scan is scoring" do
    own_property
    ready_lead(name: "Asha")

    travel_to zone.local(2026, 10, 8, 2) do
      described_class.call(firm:)
    end

    travel_to zone.local(2026, 10, 8, 11) do
      released = false
      allow_any_instance_of(described_class).to receive(:items_for).and_wrap_original do |method, previous|
        items = method.call(previous)
        unless released
          released = true
          Matches::ReleaseDigest.call(firm:)
        end
        items
      end

      described_class.call(firm:)
    end

    digest = MatchDigest.find_by(firm:)
    expect(Notification.across_firms.where(kind: "match_digest").count).to eq(1)
    expect(digest.notification_pending).to be(false)
    expect(digest.notified_fingerprint).to eq(digest.fingerprint)
  end

  it "leaves a booked lead out, including from its listing" do
    travel_to zone.local(2026, 10, 8, 11) do
      listing = own_property
      booked = ready_lead(lead_status: create(:lead_status, :booked), name: "Booked")
      ready_lead(name: "Asha")

      digest = described_class.call(firm:)

      expect(digest_lead(digest, booked)).to be_nil
      expect(digest.listing_items.find { |item| item["id"] == listing.id }["match_ids"]).not_to include(booked.id)
    end
  end

  it "keeps a catalog project whose matching configuration has no price" do
    travel_to zone.local(2026, 10, 8, 11) do
      three_bhk = create(:typology, name: "3 BHK")
      catalog = Current.set(firm: nil, firm_scope_bypassed: true) do
        create(:project, :catalog, firm: nil, city:, locality:, name: "Catalog Vista",
          starting_budget: 9_000_000, possession_on: Date.new(2026, 11, 1), possession_label: nil,
          builder: create(:builder, firm: nil)).tap do |project|
          create(:project_typology, project:, typology: two_bhk, starting_price: nil)
          create(:project_typology, project:, typology: three_bhk, starting_price: 50_000_000)
        end
      end
      lead = ready_lead(name: "Asha")

      digest = described_class.call(firm:)

      expect(digest_lead(digest, lead)["match_ids"]).to include("project:#{catalog.id}")
      expect(digest_lead(digest, lead)["match_ids"]).to eq(match_ids_for(lead))
    end
  end

  it "does not scan a firm whose subscription has lapsed" do
    subscription.update!(current_period_start: Date.new(2026, 8, 1), current_period_end: Date.new(2026, 10, 1))
    travel_to zone.local(2026, 10, 8, 11) do
      own_property
      ready_lead(name: "Asha")

      expect(described_class.call(firm:)).to be_nil
      expect(MatchDigest.find_by(firm:)).to be_nil
    end
  end

  it "drops a waiting ping when the subscription has lapsed" do
    subscription.update!(current_period_start: Date.new(2026, 8, 1), current_period_end: Date.new(2026, 10, 1))
    Current.set(firm:) do
      MatchDigest.create!(
        firm:, generated_at: Time.current, fingerprint: "abc", notification_pending: true,
        lead_items: [ { "lead_id" => "x", "new_count" => 1, "match_ids" => [ "a" ] } ],
        listing_items: []
      )
    end

    Matches::ReleaseDigest.call(firm:)

    expect(Notification.across_firms.count).to eq(0)
    expect(MatchDigest.find_by(firm:).notification_pending).to be(false)
  end

  it "does not block deleting the firm" do
    Current.set(firm:) do
      MatchDigest.create!(
        firm:, generated_at: Time.current, fingerprint: "abc",
        lead_items: [], listing_items: []
      )
    end

    expect { firm.destroy! }.not_to raise_error
  end

  it "saves an empty first scan and does not ping" do
    travel_to zone.local(2026, 10, 8, 11) do
      digest = described_class.call(firm:)

      expect(digest.lead_items).to eq([])
      expect(digest.listing_items).to eq([])
      expect(Notification.across_firms.count).to eq(0)
    end
  end

  it "keeps the push for 12 hours" do
    allow(Notifications::Vapid).to receive(:configured?).and_return(true)
    allow(Notifications::Vapid).to receive_messages(
      public_key: "test-public", private_key: "test-private", subject: "mailto:test@example.com"
    )
    allow(WebPush).to receive(:payload_send).and_return(true)
    session, = AuthSession.start!(user: super_admin, device: { device_id: "desk" })
    PushSubscription.create!(
      user: super_admin, firm:, auth_session: session,
      endpoint: "https://push.example/owner", p256dh: "p256", auth_key: "auth"
    )

    travel_to zone.local(2026, 10, 8, 11) do
      own_property
      ready_lead(name: "Asha")
      described_class.call(firm:)
    end

    expect(WebPush).to have_received(:payload_send).with(hash_including(ttl: 12.hours.to_i))
  end

  it "skips a super admin who turned notifications off" do
    travel_to zone.local(2026, 10, 8, 11) do
      super_admin.update!(notification_mode: "none")
      own_property
      ready_lead
      described_class.call(firm:)

      expect(Notification.across_firms.count).to eq(0)
      expect(MatchDigest.find_by(firm:).notified_fingerprint).to be_present
    end
  end
end
