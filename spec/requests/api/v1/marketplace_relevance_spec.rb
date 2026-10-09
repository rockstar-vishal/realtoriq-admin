# frozen_string_literal: true

require "rails_helper"

# The home strip and the unfiltered marketplace are the same order. A newer
# project in another city must not jump the firm's own locality — that is the
# failure you get if this falls back to sort=recent.
RSpec.describe "Marketplace relevance" do
  let(:plan) { create(:plan) }
  let(:city) { create(:city, name: "Mumbai", state: "Maharashtra") }
  let(:other_city) { create(:city, name: "Pune", state: "Maharashtra") }
  let(:primary) { create(:locality, city:, name: "Andheri West") }
  let(:tagged) { create(:locality, city:, name: "Bandra West") }
  let(:nearby) { create(:locality, city:, name: "Thane") }
  let(:pune_locality) { create(:locality, city: other_city, name: "Baner") }
  let(:firm) { create(:firm, status: :active, city:, locality: primary) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let!(:user) { create(:user, :super_admin, firm:) }
  let(:builder) { create(:builder, firm: nil) }

  def auth(as: user)
    post "/api/v1/auth/otp", params: { mobile: as.mobile }, as: :json
    request_id = response.parsed_body["request_id"]
    post "/api/v1/auth/verify", params: { request_id:, code: deliverer.last.code }, as: :json
    { "Authorization" => "Bearer #{response.parsed_body['access_token']}" }
  end

  def catalog!(name, city:, locality: nil, created_at: Time.current)
    Current.set(firm: nil, firm_scope_bypassed: true) do
      project = create(:project, :catalog, firm: nil, name:, builder:, city:, locality:,
        external_ref: "PR#{SecureRandom.hex(4).upcase}")
      project.update_columns(created_at:, updated_at: created_at)
      project
    end
  end

  def names(**params)
    get "/api/v1/projects", params: params.merge(source: "catalog"), headers: auth
    response.parsed_body["projects"].map { |project| project["name"] }
  end

  before do
    FirmLocality.create!(firm:, locality: tagged)
  end

  it "ranks primary, then other tagged localities, then the rest of those cities, then everywhere else" do
    catalog!("Elsewhere", city: other_city, locality: pune_locality, created_at: Time.current)
    catalog!("City only", city:, locality: nil, created_at: 12.hours.ago)
    catalog!("Nearby", city:, locality: nearby, created_at: 1.day.ago)
    catalog!("Tagged", city:, locality: tagged, created_at: 2.days.ago)
    catalog!("Primary", city:, locality: primary, created_at: 3.days.ago)

    expect(names(sort: "relevant")).to eq(
      [ "Primary", "Tagged", "City only", "Nearby", "Elsewhere" ]
    )
  end

  it "keeps newest first inside a band when nearby matching is off, even if centers exist" do
    primary.update!(lat: 19.05, lng: 73.07)
    near = Inventory::Geo.offset(19.05, 73.07, north_m: 4_000)
    catalog!("Near older", city:, locality: primary, created_at: 3.days.ago)
    far = catalog!("Far newer", city:, locality: primary, created_at: Time.current)
    far.update!(lat: near[0], lng: near[1])

    expect(names(sort: "relevant")).to eq([ "Far newer", "Near older" ])
  end

  it "puts a geographic neighbor after tagged localities once nearby matching is on" do
    NearbyMatching.enable!
    primary.update!(lat: 19.05, lng: 73.07)
    close = Inventory::Geo.offset(19.05, 73.07, north_m: 2_000)
    far = Inventory::Geo.offset(19.05, 73.07, east_m: 12_000)
    nearby.update!(lat: close[0], lng: close[1])
    tagged.update!(lat: far[0], lng: far[1])

    catalog!("Elsewhere", city: other_city, locality: pune_locality, created_at: Time.current)
    catalog!("City only", city:, locality: nil, created_at: 12.hours.ago)
    catalog!("Nearby", city:, locality: nearby, created_at: 1.day.ago)
    catalog!("Tagged", city:, locality: tagged, created_at: 2.days.ago)
    catalog!("Primary", city:, locality: primary, created_at: 3.days.ago)

    expect(names(sort: "relevant")).to eq(
      [ "Primary", "Tagged", "Nearby", "City only", "Elsewhere" ]
    )
  ensure
    NearbyMatching.delete_all
  end

  it "orders a band by distance to the tagged center once nearby matching is on" do
    NearbyMatching.enable!
    primary.update!(lat: 19.05, lng: 73.07)
    near = Inventory::Geo.offset(19.05, 73.07, north_m: 4_000)
    catalog!("Near older", city:, locality: primary, created_at: 3.days.ago).update!(lat: 19.05, lng: 73.07)
    catalog!("Far newer", city:, locality: primary, created_at: Time.current).update!(lat: near[0], lng: near[1])

    expect(names(sort: "relevant")).to eq([ "Near older", "Far newer" ])
  ensure
    NearbyMatching.delete_all
  end

  it "does not include the firm's own projects" do
    catalog!("Primary", city:, locality: primary, created_at: 2.days.ago)
    create(:project, firm:, name: "Mine", builder:, city:, locality: primary)

    expect(names(sort: "relevant")).to eq([ "Primary" ])
  end

  it "orders a firm with no locality newest first" do
    firm.update!(locality: nil, city: nil)
    catalog!("Older", city:, locality: primary, created_at: 2.days.ago)
    catalog!("Newer", city: other_city, locality: pune_locality, created_at: Time.current)

    expect(names(sort: "relevant")).to eq([ "Newer", "Older" ])
  end

  it "gives another firm its own order" do
    catalog!("Mumbai project", city:, locality: primary, created_at: 1.day.ago)
    catalog!("Pune project", city: other_city, locality: pune_locality, created_at: 2.days.ago)

    other_firm = create(:firm, status: :active, city: other_city, locality: pune_locality)
    create(:subscription, firm: other_firm, plan:)
    other_user = create(:user, :super_admin, firm: other_firm)

    get "/api/v1/projects", params: { source: "catalog", sort: "relevant" }, headers: auth(as: other_user)

    expect(response.parsed_body["projects"].map { |project| project["name"] })
      .to eq([ "Pune project", "Mumbai project" ])
  end

  it "stays A–Z when a search is sent with sort=relevant" do
    catalog!("Zeta Plaza", city:, locality: primary, created_at: Time.current)
    catalog!("Alpha Plaza", city: other_city, locality: pune_locality, created_at: 2.days.ago)

    expect(names(sort: "relevant", q: "Plaza")).to eq([ "Alpha Plaza", "Zeta Plaza" ])
  end

  it "stays newest first when a drawer filter is sent with sort=relevant" do
    catalog!("Older primary", city:, locality: primary, created_at: 2.days.ago)
    catalog!("Newer nearby", city:, locality: nearby, created_at: Time.current)

    expect(names(sort: "relevant", city_id: city.id)).to eq([ "Newer nearby", "Older primary" ])
  end

  it "does not rank My Projects" do
    # Zephyr is newer, so newest-first would put it first. A–Z puts Aurum first.
    create(:project, firm:, name: "Zephyr", builder:, city:, locality: primary, created_at: Time.current)
    create(:project, firm:, name: "Aurum", builder:, city: other_city, locality: pune_locality, created_at: 2.days.ago)

    get "/api/v1/projects", params: { sort: "relevant" }, headers: auth

    expect(response.parsed_body["projects"].map { |project| project["name"] }).to eq([ "Aurum", "Zephyr" ])
  end

  it "pages without repeating or dropping a project" do
    5.times do |n|
      catalog!("Page #{n}", city:, locality: primary, created_at: n.hours.ago)
    end
    headers = auth

    get "/api/v1/projects", params: { source: "catalog", sort: "relevant", per_page: 50 }, headers: headers
    expected = response.parsed_body["projects"].map { |project| project["id"] }

    seen = []
    (1..3).each do |page|
      get "/api/v1/projects", params: { source: "catalog", sort: "relevant", per_page: 2, page: }, headers: headers
      seen.concat(response.parsed_body["projects"].map { |project| project["id"] })
    end

    expect(seen).to eq(expected)
  end
end
