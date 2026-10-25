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
      city:, locality:)
  end

  def match_ids_for(lead)
    Inventory::MatchInventory.new(lead:).call.map { |row| "#{row[:kind]}:#{row[:id]}" }
  end

  def digest_lead(digest, lead)
    digest.lead_items.find { |item| item["lead_id"] == lead.id }
  end

  it "ignores the category and area keys when it fingerprints a digest" do
    bare = {
      "lead_items" => [ { "lead_id" => "lead-1", "match_ids" => %w[match-b match-a] } ],
      "listing_items" => [ { "kind" => "property", "id" => "listing-1", "match_ids" => %w[lead-z lead-y] } ]
    }
    richer = {
      "lead_items" => [ {
        "lead_id" => "lead-1", "match_ids" => %w[match-b match-a],
        "category" => "commercial", "area" => { "min" => "800", "unit" => "sqft" },
        "prefers_pre_leased" => true
      } ],
      "listing_items" => [ {
        "kind" => "property", "id" => "listing-1", "match_ids" => %w[lead-z lead-y],
        "categories" => %w[commercial]
      } ]
    }

    expect(described_class.fingerprint(richer["lead_items"], richer["listing_items"]))
      .to eq(described_class.fingerprint(bare["lead_items"], bare["listing_items"]))
  end

  it "stores the same unlinked matches the live matcher would, and tells the super admin" do
    travel_to zone.local(2026, 10, 8, 11) do
      project = own_project
      listing = own_property
      mapped = own_property
      shared = create(:property, firm: other_firm, typology: two_bhk, price: 10_000_000, listed_on_marketplace: true,
        city:, locality:)
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
      expect(digest_lead(digest, lead)["category"]).to eq("residential")
      expect(digest_lead(digest, lead)["prefers_pre_leased"]).to be(false)
      expect(digest_lead(digest, lead)["area"].keys).to include("min", "max", "unit", "min_sqft", "max_sqft")
      expect(digest.listing_items.find { |item| item["id"] == listing.id }["categories"]).to eq([ "residential" ])
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

  it "keeps the pending flag and the push on the same side of the night" do
    own_property
    ready_lead(name: "Asha")
    allow(Matches::Slot).to receive(:quiet?).and_return(true, false)

    travel_to zone.local(2026, 10, 8, 21) do
      digest = described_class.call(firm:)

      expect(Matches::Slot).to have_received(:quiet?).once
      expect(digest.notification_pending).to be(true)
      expect(digest.notified_fingerprint).to be_nil
      expect(Notification.across_firms.count).to eq(0)
    end
  end

  it "sends the push when the one quiet-hours reading is daytime" do
    own_property
    ready_lead(name: "Asha")
    allow(Matches::Slot).to receive(:quiet?).and_return(false, true)

    travel_to zone.local(2026, 10, 8, 8) do
      digest = described_class.call(firm:)

      expect(Matches::Slot).to have_received(:quiet?).once
      expect(digest.notification_pending).to be(false)
      expect(digest.notified_fingerprint).to eq(digest.fingerprint)
      expect(Notification.across_firms.where(kind: "match_digest").count).to eq(1)
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

  it "saves the digest when that fingerprint was already announced" do
    fingerprint = nil
    first_at = nil
    travel_to zone.local(2026, 10, 8, 11) do
      own_property
      ready_lead(name: "Asha")
      first = described_class.call(firm:)
      fingerprint = first.fingerprint
      first_at = first.generated_at
      first.update!(
        fingerprint: "other-list",
        lead_items: first.lead_items.map { |item| item.merge("match_ids" => [ "gone" ], "new_count" => 0) },
        listing_items: []
      )
    end

    travel_to zone.local(2026, 10, 8, 12) do
      expect { described_class.call(firm:) }.not_to raise_error
    end

    saved = MatchDigest.find_by!(firm:)
    expect(saved.generated_at).to be > first_at
    expect(saved.fingerprint).to eq(fingerprint)
    expect(Notification.across_firms.where(kind: "match_digest").count).to eq(1)
  end

  it "releases a digest whose fingerprint was already announced" do
    fingerprint = nil
    travel_to zone.local(2026, 10, 8, 2) do
      own_property
      ready_lead(name: "Asha")
      digest = described_class.call(firm:)
      fingerprint = digest.fingerprint
      super_admin.notifications.create!(
        firm:, kind: "match_digest", title: "New matches are ready", body: "Already sent",
        dedupe_key: "match_digest:#{fingerprint}", data: { "page" => "matches" }
      )
    end

    expect { Matches::ReleaseDigest.call(firm:) }.not_to raise_error
    saved = MatchDigest.find_by!(firm:)
    expect(saved.notification_pending).to be(false)
    expect(saved.notified_fingerprint).to eq(fingerprint)
    expect(Notification.across_firms.where(kind: "match_digest").count).to eq(1)
  end

  it "keeps the saved digest when the push raises" do
    allow(Matches::Notify).to receive(:call).and_raise(RuntimeError, "push down")
    travel_to zone.local(2026, 10, 8, 11) do
      own_property
      ready_lead(name: "Asha")
      expect { described_class.call(firm:) }.not_to raise_error
    end

    digest = MatchDigest.find_by!(firm:)
    expect(digest.notification_pending).to be(false)
    expect(digest.notified_fingerprint).to eq(digest.fingerprint)
    expect(Notification.across_firms.count).to eq(0)
  end

  it "keeps a released digest when the push raises" do
    travel_to zone.local(2026, 10, 8, 2) do
      own_property
      ready_lead(name: "Asha")
      described_class.call(firm:)
    end
    allow(Matches::Notify).to receive(:call).and_raise(RuntimeError, "push down")

    expect { Matches::ReleaseDigest.call(firm:) }.not_to raise_error
    digest = MatchDigest.find_by!(firm:)
    expect(digest.notification_pending).to be(false)
    expect(digest.notified_fingerprint).to eq(digest.fingerprint)
  end

  it "does not treat a lead moving from 31st to 30th as new" do
    travel_to zone.local(2026, 10, 8, 11) do
      own_property
      leads = Array.new(31) { |index| ready_lead(name: format("Buyer %02d", index + 1)) }
      described_class.call(firm:)
      expect(MatchDigest.find_by!(firm:).lead_items.size).to eq(31)
      expect(MatchDigest.find_by!(firm:).lead_items.last["name"]).to eq("Buyer 31")

      leads.first.update!(unqualified: true)

      expect { described_class.call(firm:) }
        .not_to change { Notification.across_firms.where(kind: "match_digest").count }
      moved = digest_lead(MatchDigest.find_by!(firm:), leads.last)
      expect(moved["new_count"]).to eq(0)
      expect(MatchDigest.find_by!(firm:).lead_items.map { |item| item["lead_id"] }.index(leads.last.id)).to eq(29)
    end
  end

  it "counts a ping from the 30 rows the page shows" do
    lead_items = Array.new(30) { |index| { "lead_id" => "l#{index}", "new_count" => 0, "match_ids" => [] } }
    lead_items[0]["new_count"] = 1
    lead_items << { "lead_id" => "extra", "new_count" => 4, "match_ids" => [ "x" ] }
    digest = MatchDigest.create!(
      firm:, generated_at: Time.current, fingerprint: "shown-thirty",
      lead_items:, listing_items: []
    )

    Matches::Notify.call(digest:)

    expect(Notification.across_firms.find_by!(kind: "match_digest").body).to eq("1 lead has new options")
  end

  it "drops the price cap when a lead has no budget" do
    ready_lead(name: "Priced")
    bare = create(:lead, firm:, lead_status: live_status, budget_max: nil, budget_min: nil,
      transaction_type: "sale", property_type: ready_type, name: "Bare")
    bare.typologies << two_bhk
    bare.localities << locality
    shared = create(:property, firm: other_firm, typology: two_bhk, price: 50_000_000, listed_on_marketplace: true,
      city:, locality:)

    travel_to zone.local(2026, 10, 8, 11) do
      digest = described_class.call(firm:, announce: false)

      expect(described_class.new(firm:).send(:price_cap)).to be_nil
      expect(digest_lead(digest, bare)["match_ids"]).to include("property:#{shared.id}")
      expect(Array(digest_lead(digest, ready_lead_named("Priced"))&.dig("match_ids"))).not_to include("property:#{shared.id}")
    end
  end

  it "stores the highest score, not the first band, as top_score" do
    NearbyMatching.enable!
    shop = create(:typology, name: "Shop", code: "shop_top_score", category: "commercial")
    kharghar = locality
    panvel = create(:locality, city:, name: "Panvel")
    place(kharghar)
    place(panvel, east_m: 2_000)
    lead = create(:lead, firm:, lead_status: live_status, budget_max: 10_000_000, category: "commercial",
      transaction_type: "sale", property_type: ready_type, name: "Asha",
      area_min_value: 1_000, area_max_value: 1_000, area_unit: "sqft")
    lead.typologies << shop
    lead.localities << kharghar
    anchor = shop_at(shop, kharghar, price: 10_000_000, area_value: 1_000)
    lead.lead_properties.create!(property: anchor, firm:)
    pin = shop_at(shop, panvel, price: 12_000_000, area_value: 1_000, north_m: 0, east_m: 2_000)
    preferred = shop_at(shop, kharghar, price: 10_000_000, area_value: 800, north_m: 7_000)

    travel_to zone.local(2026, 10, 8, 11) do
      rows = Inventory::MatchInventory.new(lead:).call
      expect(rows.map { |row| [ row[:id], row[:score] ] }).to eq([ [ pin.id, 60 ], [ preferred.id, 90 ] ])

      digest = described_class.call(firm:, announce: false)
      expect(digest_lead(digest, lead)["top_score"]).to eq(90)
    end
  ensure
    NearbyMatching.delete_all
  end

  it "uses the highest buyer score as a listing top_score" do
    NearbyMatching.enable!
    kharghar = locality
    panvel = create(:locality, city:, name: "Panvel Far")
    place(kharghar)
    place(panvel, east_m: 12_000)
    lat, lng = shifted
    listing = create(:property, firm:, typology: two_bhk, price: 10_000_000,
      city:, locality: kharghar, lat:, lng:)
    preferred = ready_lead(name: "Zara")
    pin_lead = create(:lead, firm:, lead_status: live_status, budget_max: 8_000_000,
      transaction_type: "sale", property_type: ready_type, name: "Aaron")
    pin_lead.typologies << two_bhk
    pin_lead.localities << panvel
    hook_lat, hook_lng = shifted(north_m: 2_000)
    hook = create(:project, firm:, city:, locality: kharghar, name: "Hook Tower", starting_budget: 10_000_000,
      possession_on: Date.new(2027, 6, 1), possession_label: nil, lat: hook_lat, lng: hook_lng)
    create(:project_typology, project: hook, typology: two_bhk, starting_price: 10_000_000)
    pin_lead.lead_projects.create!(project: hook, firm:)

    travel_to zone.local(2026, 10, 8, 11) do
      digest = described_class.call(firm:, announce: false)
      item = digest.listing_items.find { |row| row["id"] == listing.id }

      expect(item["match_ids"]).to eq([ pin_lead.id, preferred.id ])
      expect(item["top_score"]).to eq(100)
    end
  ensure
    NearbyMatching.delete_all
  end

  def shifted(north_m: 0, east_m: 0)
    Inventory::Geo.offset(19.05, 73.07, north_m:, east_m:)
  end

  def place(locality, north_m: 0, east_m: 0)
    lat, lng = shifted(north_m:, east_m:)
    locality.update!(lat:, lng:)
    [ lat, lng ]
  end

  def shop_at(typology, locality, price:, area_value:, north_m: 0, east_m: 0)
    lat, lng = shifted(north_m:, east_m:)
    create(:property, firm:, typology:, price:, area_value:, area_unit: "sqft",
      city:, locality:, lat:, lng:)
  end

  def ready_lead_named(name)
    Lead.find_by!(firm:, name:)
  end
end
