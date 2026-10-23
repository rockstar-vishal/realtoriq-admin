# frozen_string_literal: true

require "rails_helper"

RSpec.describe "categorised matching examples" do
  include ActiveSupport::Testing::TimeHelpers

  let(:firm) { create(:firm) }
  let!(:subscription) { create(:subscription, firm:) }
  let!(:user) { create(:user, :super_admin, firm:) }
  let(:city) { create(:city, name: "Thane") }
  let(:locality) { create(:locality, city:, name: "Kolshet") }
  let(:status) { create(:lead_status, :new_lead) }
  let(:ready_type) { create(:property_type, name: "Ready possession") }
  let(:under_type) { create(:property_type, name: "Under construction") }
  let(:two_bhk) { create(:typology, name: "2 BHK", code: "2_bhk") }
  let(:three_bhk) { create(:typology, name: "3 BHK", code: "3_bhk") }
  let(:office) { create(:typology, name: "Office", code: "office", category: "commercial") }
  let(:shop) { create(:typology, name: "Shop", code: "shop", category: "commercial") }
  let(:plot) { create(:typology, name: "Residential plot", code: "residential_plot", category: "land") }
  let(:farm) { create(:typology, name: "Agricultural land", code: "agricultural_land", category: "land") }

  before { Current.firm = firm }
  after { Current.reset }

  around do |example|
    travel_to(Time.find_zone("Asia/Kolkata").local(2026, 9, 15, 12)) { example.run }
  end

  def add_lead(typology, category: typology.category, transaction_type: "sale", budget: 10_000_000,
    property_type: nil, owner: firm, **attrs)
    type = if category == "land" || transaction_type == "rent"
      nil
    else
      property_type || under_type
    end
    Current.set(firm: owner) do
      create(:lead, firm: owner, lead_status: status, category:, transaction_type:, property_type: type,
        budget_max: budget, **attrs).tap do |lead|
        lead.typologies << typology
        lead.localities << locality
      end
    end
  end

  def add_property(typology, price:, listing_for: "sale", owner: firm, area_value: nil, area_unit: "sqft",
    carpet_area_sqft: nil, pre_leased: false)
    create(:property, firm: owner, typology:, listing_for:, price:, area_value:, area_unit:, carpet_area_sqft:,
      pre_leased:, details: pre_leased ? { "lease_monthly_rent" => 100_000 } : {},
      building: create(:building, firm: owner, city:, locality:))
  end

  def add_project(name:, starting_budget:, possession_on:, rows:)
    create(:project, firm:, city:, locality:, name:, starting_budget:, possession_on:, possession_label: nil).tap do |project|
      rows.each { |row| create(:project_typology, { project: }.merge(row)) }
    end
  end

  def inventory_for(lead)
    Inventory::MatchInventory.new(lead:).call
  end

  def lead_rows(record)
    args = record.is_a?(Project) ? { project: record } : { property: record }
    Inventory::MatchLeads.new(user:, **args).call
  end

  def curated_ids(lead)
    Matches::CurateFirm.call(firm: lead.firm, announce: false)
    item = MatchDigest.find_by(firm: lead.firm)&.lead_items&.find { |row| row["lead_id"] == lead.id }
    Array(item && item["match_ids"])
  end

  def mirror_of(lead)
    owner = create(:firm)
    Current.set(firm: owner) do
      create(:lead, firm: owner, lead_status: status, category: lead.category, transaction_type: lead.transaction_type,
        property_type: lead.property_type, budget_max: lead.budget_max, prefers_pre_leased: lead.prefers_pre_leased,
        area_min_value: lead.area_min_value, area_max_value: lead.area_max_value, area_unit: lead.area_unit).tap do |copy|
        lead.typologies.each { |typology| copy.typologies << typology }
        copy.localities << locality
      end
    end
  end

  def property_paths(lead, property)
    mirror = mirror_of(lead)
    marketplace = Inventory::MarketplaceLeadMatches.new(property:).call
    firms = Inventory::MarketplaceFirms.new(property:).call
    {
      inventory: inventory_for(lead).find { |row| row[:id] == property.id },
      leads: lead_rows(property).find { |row| row[:id] == lead.id },
      marketplace: marketplace.find { |row| row[:firm_id] == mirror.firm_id && row[:code] == mirror.code },
      firms: firms.find { |row| row[:id] == mirror.firm_id },
      curated: curated_ids(lead).include?("property:#{property.id}")
    }
  end

  def project_paths(lead, project)
    {
      inventory: inventory_for(lead).find { |row| row[:id] == project.id },
      leads: lead_rows(project).find { |row| row[:id] == lead.id },
      curated: curated_ids(lead).include?("project:#{project.id}")
    }
  end

  def expect_hidden_property(lead, property)
    paths = property_paths(lead, property)
    expect(paths[:inventory]).to be_nil
    expect(paths[:leads]).to be_nil
    expect(paths[:marketplace]).to be_nil
    expect(paths[:firms]).to be_nil
    expect(paths[:curated]).to be(false)
  end

  def expect_shown_property(lead, property, score:, configuration: :skip, area: :skip, matched_on: nil)
    paths = property_paths(lead, property)
    [ paths[:inventory], paths[:leads] ].each do |row|
      expect(row[:score]).to eq(score)
      expect(row[:score_breakdown][:configuration]).to eq(configuration) unless configuration == :skip
      expect(row[:score_breakdown][:area]).to eq(area) unless area == :skip
      expect(row[:score_breakdown][:fit]).to eq(configuration.nil? ? area : configuration)
      expect(row[:matched_on]).to eq(matched_on) if matched_on
    end
    if score > Inventory::MatchInventory::MARKETPLACE_FLOOR
      expect(paths[:marketplace]).to be_present
      expect(paths[:firms]).to be_present
    else
      expect(paths[:marketplace]).to be_nil
      expect(paths[:firms]).to be_nil
    end
    expect(paths[:curated]).to be(true)
    paths
  end

  def expect_hidden_project(lead, project)
    paths = project_paths(lead, project)
    expect(paths[:inventory]).to be_nil
    expect(paths[:leads]).to be_nil
    expect(paths[:curated]).to be(false)
  end

  def expect_shown_project(lead, project, score:)
    paths = project_paths(lead, project)
    expect(paths[:inventory][:score]).to eq(score)
    expect(paths[:leads][:score]).to eq(score)
    expect(paths[:curated]).to be(true)
    paths
  end

  it "does not show a shop to a residential buyer" do
    listing = add_property(shop, price: 8_000_000, area_value: 400)
    under = add_lead(two_bhk, budget: 10_000_000, property_type: under_type)
    ready = add_lead(two_bhk, budget: 10_000_000, property_type: ready_type)

    expect_hidden_property(under, listing)
    expect_hidden_property(ready, listing)
    expect(subscription).to be_present
  end

  it "shows a different residential configuration with no configuration points" do
    listing = add_property(three_bhk, price: 10_000_000, area_value: 900)
    lead = add_lead(two_bhk, budget: 10_000_000, property_type: ready_type)

    paths = expect_shown_property(lead, listing, score: 80, configuration: 0, area: nil,
      matched_on: %w[locality price])
    expect(paths[:inventory][:score_breakdown][:bonus]).to eq(0)
    expect(paths[:inventory][:matched_configuration]).to be_nil
  end

  it "shows one project row for Ultima and Optima and prices Ultima" do
    project = add_project(name: "Twin", starting_budget: 11_000_000, possession_on: Date.new(2027, 6, 1), rows: [
      { typology: two_bhk, label: "Ultima", starting_price: 11_000_000 },
      { typology: two_bhk, label: "Optima", starting_price: 12_500_000 }
    ])
    lead = add_lead(two_bhk, budget: 12_000_000, property_type: under_type)

    paths = expect_shown_project(lead, project, score: 100)
    expect(inventory_for(lead).count { |row| row[:id] == project.id }).to eq(1)
    expect(paths[:inventory][:matched_configuration]).to eq("2 BHK Ultima")
    expect(paths[:inventory][:score_breakdown]).to include(configuration: 20, fit: 20, area: nil, bonus: 0)
    expect(paths[:leads][:matched_configuration]).to eq("2 BHK Ultima")
    expect(paths[:leads][:score_breakdown][:configuration]).to eq(20)
  end

  it "scores a 3 BHK stored with the label Villa the same way as 3 BHK" do
    project = Current.set(firm: nil, firm_scope_bypassed: true) do
      create(:project, :catalog, firm: nil, city:, locality:, name: "Villa Row", starting_budget: 15_000_000,
        possession_on: Date.new(2027, 6, 1), possession_label: nil, builder: create(:builder, firm: nil)).tap do |row|
        create(:project_typology, project: row, typology: three_bhk, label: "Villa", starting_price: 15_000_000)
      end
    end
    lead = add_lead(three_bhk, budget: 16_000_000, property_type: under_type)

    paths = expect_shown_project(lead, project, score: 100)
    expect(project.project_typologies.first.display_name).to eq("3 BHK Villa")
    expect(paths[:inventory][:matched_configuration]).to eq("3 BHK Villa")
    expect(paths[:inventory][:score_breakdown][:configuration]).to eq(20)
    expect(paths[:leads][:score_breakdown][:configuration]).to eq(20)
  end

  it "gives 20 area points to an office inside the lead's range" do
    listing = add_property(office, price: 40_000, listing_for: "rent", area_value: 1_100)
    lead = add_lead(office, transaction_type: "rent", budget: 50_000, area_min_value: 800, area_max_value: 1_200, area_unit: "sqft")

    paths = expect_shown_property(lead, listing, score: 100, configuration: nil, area: 20,
      matched_on: %w[locality price area])
    expect(paths[:inventory][:area_sqft]).to eq(1_100)
    expect(paths[:inventory][:pre_leased]).to be(false)
    expect(paths[:inventory][:category]).to eq("commercial")
  end

  it "stays at 30, and unlisted, when the lead has no area and the office is far over budget" do
    listing = add_property(office, price: 60_000, listing_for: "rent", area_value: 1_100)
    lead = add_lead(office, transaction_type: "rent", budget: 20_000)

    expect_hidden_property(lead, listing)
    breakdown = Inventory::MatchScore.for_offers(
      budget: lead.budget_amount, offers: [ Inventory::MatchScore.offer_for_property(listing) ],
      lead_keys: [ "office" ], fit: :area, lead:
    )
    expect(breakdown[:location] + breakdown[:price] + breakdown[:fit]).to eq(30)
    expect(breakdown[:area]).to eq(0)
  end

  it "shows an office with no area on price alone, behind one that fits" do
    fitting = add_property(office, price: 40_000, listing_for: "rent", area_value: 1_100)
    blank = add_property(office, price: 40_000, listing_for: "rent")
    lead = add_lead(office, transaction_type: "rent", budget: 50_000, area_min_value: 800, area_max_value: 1_200, area_unit: "sqft")

    expect(blank.reload.carpet_area_sqft).to be_nil
    shown = expect_shown_property(lead, blank, score: 80, configuration: nil, area: 0, matched_on: %w[locality price])
    expect(shown[:inventory][:score_breakdown][:area]).to eq(0)
    expect_shown_property(lead, fitting, score: 100, configuration: nil, area: 20)

    wanted = [ fitting.id, blank.id ]
    expect(inventory_for(lead).map { |row| row[:id] } & wanted).to eq(wanted)
    expect(curated_ids(lead).select { |token| wanted.any? { |id| token.end_with?(id) } })
      .to eq(wanted.map { |id| "property:#{id}" })
  end

  it "does not show a shop to an office lead" do
    listing = add_property(shop, price: 40_000, listing_for: "rent", area_value: 400)
    lead = add_lead(office, transaction_type: "rent", budget: 50_000)

    expect_hidden_property(lead, listing)
  end

  it "keeps both capped shops at 100 and sorts the pre-leased one first" do
    vacant = add_property(shop, price: 10_000_000, area_value: 1_000)
    leased = add_property(shop, price: 10_000_000, area_value: 1_100, pre_leased: true)
    keen = add_lead(shop, budget: 10_000_000, property_type: ready_type, prefers_pre_leased: true,
      area_min_value: 800, area_max_value: 1_200, area_unit: "sqft")
    plain = add_lead(shop, budget: 10_000_000, property_type: ready_type, prefers_pre_leased: false,
      area_min_value: 800, area_max_value: 1_200, area_unit: "sqft")

    leased_paths = expect_shown_property(keen, leased, score: 100, configuration: nil, area: 20)
    expect(leased_paths[:inventory][:score_breakdown][:bonus]).to eq(10)
    expect(leased_paths[:inventory][:matched_on]).to include("pre_leased")
    expect(leased_paths[:inventory][:pre_leased]).to be(true)
    expect_shown_property(keen, vacant, score: 100, configuration: nil, area: 20)

    wanted = [ leased.id, vacant.id ]
    expect(inventory_for(keen).map { |row| row[:id] } & wanted).to eq(wanted)
    expect(curated_ids(keen).select { |token| wanted.any? { |id| token.end_with?(id) } })
      .to eq(wanted.map { |id| "property:#{id}" })

    expect(inventory_for(plain).map { |row| row[:id] } & wanted).to eq([ vacant.id, leased.id ])
    expect(curated_ids(plain).select { |token| wanted.any? { |id| token.end_with?(id) } })
      .to eq([ "property:#{vacant.id}", "property:#{leased.id}" ])

    buyer_order = lead_rows(leased).map { |row| row[:id] } & [ keen.id, plain.id ]
    expect(buyer_order).to eq([ keen.id, plain.id ])
  end

  it "ranks a pre-leased shop at 90 ahead of a vacant shop at 80" do
    leased = add_property(shop, price: 10_000_000, pre_leased: true)
    vacant = add_property(shop, price: 11_500_000, area_value: 1_000)
    lead = add_lead(shop, budget: 10_000_000, property_type: ready_type, prefers_pre_leased: true,
      area_min_value: 800, area_max_value: 1_200, area_unit: "sqft")

    expect(leased.reload.carpet_area_sqft).to be_nil
    expect_shown_property(lead, leased, score: 90, configuration: nil, area: 0)
    expect_shown_property(lead, vacant, score: 80, configuration: nil, area: 20)
    wanted = [ leased.id, vacant.id ]
    expect(inventory_for(lead).map { |row| row[:id] } & wanted).to eq(wanted)
    expect(curated_ids(lead).select { |token| wanted.any? { |id| token.end_with?(id) } })
      .to eq(wanted.map { |id| "property:#{id}" })
  end

  it "hides an under-construction shop project from a ready commercial buyer" do
    later = add_project(name: "Later shops", starting_budget: 8_000_000, possession_on: Date.new(2027, 6, 1), rows: [
      { typology: shop, starting_price: 8_000_000, area_value: 400, area_unit: "sqft" }
    ])
    soon = add_project(name: "Soon shops", starting_budget: 8_000_000, possession_on: Date.new(2026, 10, 1), rows: [
      { typology: shop, starting_price: 8_000_000, area_value: 400, area_unit: "sqft" }
    ])
    lead = add_lead(shop, budget: 10_000_000, property_type: ready_type)

    expect_hidden_project(lead, later)
    paths = expect_shown_project(lead, soon, score: 80)
    expect(paths[:inventory][:score_breakdown][:area]).to eq(0)
  end

  it "scores a residential plot of 3 guntha inside 2 to 4 guntha" do
    listing = add_property(plot, price: 4_500_000, area_value: 3, area_unit: "guntha")
    lead = add_lead(plot, budget: 5_000_000, area_min_value: 2, area_max_value: 4, area_unit: "guntha")

    paths = expect_shown_property(lead, listing, score: 100, configuration: nil, area: 20,
      matched_on: %w[locality price area])
    expect(paths[:inventory][:area][:kind]).to eq("plot")
    expect(paths[:inventory][:area_sqft]).to eq(3_267)
    expect(listing.reload.carpet_area_sqft).to eq(3_267)
  end

  it "does not show agricultural land to a residential-plot lead" do
    listing = add_property(farm, price: 4_500_000, area_value: 3, area_unit: "guntha")
    lead = add_lead(plot, budget: 5_000_000)

    expect_hidden_property(lead, listing)
  end

  it "shows a plotted project whatever its possession date" do
    # A ready-possession row has to exist. Otherwise NOT IN (empty) keeps a
    # null property type, and dropping the land arm of the possession SQL
    # would still return this lead.
    ready_type
    past = add_project(name: "Old plots", starting_budget: 4_000_000, possession_on: Date.new(2025, 1, 1), rows: [
      { typology: plot, starting_price: 4_000_000, area_value: 3, area_unit: "guntha" }
    ])
    later = add_project(name: "New plots", starting_budget: 4_000_000, possession_on: Date.new(2028, 6, 1), rows: [
      { typology: plot, starting_price: 4_000_000, area_value: 3, area_unit: "guntha" }
    ])
    lead = add_lead(plot, budget: 5_000_000, area_min_value: 2, area_max_value: 4, area_unit: "guntha")

    [ past, later ].each do |project|
      paths = expect_shown_project(lead, project, score: 100)
      expect(paths[:inventory][:score_breakdown]).to include(area: 20, configuration: nil)
    end
  end

  it "shows a residential buyer only the home price on a mixed project" do
    project = add_project(name: "Mixed", starting_budget: 4_000_000, possession_on: Date.new(2027, 6, 1), rows: [
      { typology: two_bhk, starting_price: 9_000_000 },
      { typology: shop, starting_price: 4_000_000 }
    ])
    lead = add_lead(two_bhk, budget: 10_000_000, property_type: under_type)

    paths = expect_shown_project(lead, project, score: 100)
    expect(paths[:inventory][:starting_budget]).to eq(9_000_000)
    expect(paths[:inventory][:matched_price]).to eq(9_000_000)
    expect(paths[:inventory][:matched_configuration]).to eq("2 BHK")
    expect(paths[:leads][:matched_price]).to eq(9_000_000)
    expect(paths[:inventory].values).not_to include(4_000_000)
  end

  it "does not price an unpriced office from an unpicked showroom" do
    showroom = create(:typology, name: "Showroom", code: "showroom", category: "commercial")
    project = add_project(name: "Commercial mix", starting_budget: 15_000_000, possession_on: Date.new(2027, 6, 1), rows: [
      { typology: two_bhk, starting_price: 15_000_000 },
      { typology: showroom, starting_price: 10_000_000, area_value: 2_000, area_unit: "sqft" },
      { typology: office, starting_price: nil, area_value: 1_000, area_unit: "sqft" },
      { typology: shop, starting_price: 20_000_000, area_value: 200, area_unit: "sqft" }
    ])
    lead = add_lead(office, budget: 10_000_000, property_type: under_type,
      area_min_value: 1_000, area_max_value: 1_000, area_unit: "sqft")
    lead.typologies << shop

    paths = project_paths(lead, project)
    [ paths[:inventory], paths[:leads] ].each do |row|
      expect(row[:matched_configuration]).to eq("Office")
      expect(row[:score_breakdown][:price]).to eq(0)
      expect(row[:matched_price]).to be_nil
      expect(row[:matched_on]).not_to include("price")
    end
    expect(paths[:inventory][:score_breakdown][:area]).to eq(20)
  end

  it "gives a residential buyer no price points when the home rows are unpriced" do
    project = add_project(name: "Shop priced", starting_budget: 4_000_000, possession_on: Date.new(2027, 6, 1), rows: [
      { typology: two_bhk, starting_price: nil, starting_carpet_sqft: 700 },
      { typology: shop, starting_price: 4_000_000 }
    ])
    lead = add_lead(two_bhk, budget: 10_000_000, property_type: under_type)

    paths = expect_shown_project(lead, project, score: 50)
    expect(paths[:inventory][:starting_budget]).to be_nil
    expect(paths[:inventory][:matched_price]).to be_nil
    expect(paths[:inventory][:score_breakdown]).to include(price: 0, configuration: 20, fit: 20)
    expect(paths[:leads][:matched_price]).to be_nil
    expect(paths[:leads][:score_breakdown][:price]).to eq(0)
    expect(paths[:inventory].values).not_to include(4_000_000)
  end

  it "lists a project with two shop rows once" do
    project = add_project(name: "Two shops", starting_budget: 8_000_000, possession_on: Date.new(2027, 6, 1), rows: [
      { typology: shop, label: "Front", starting_price: 8_000_000 },
      { typology: shop, label: "Rear", starting_price: 7_000_000 }
    ])
    lead = add_lead(shop, budget: 10_000_000, property_type: under_type)

    expect(inventory_for(lead).count { |row| row[:id] == project.id }).to eq(1)
    expect(lead_rows(project).count { |row| row[:id] == lead.id }).to eq(1)
    expect(curated_ids(lead).count { |token| token == "project:#{project.id}" }).to eq(1)
  end

  it "prefilters projects by a category subquery and properties by a category join" do
    lead = add_lead(two_bhk, property_type: ready_type)
    sqls = []
    ActiveSupport::Notifications.subscribed(->(*, payload) { sqls << payload[:sql] }, "sql.active_record") do
      inventory_for(lead)
    end
    project_sql = sqls.find { |sql| sql.start_with?('SELECT "projects"."id"') }
    property_sql = sqls.find { |sql|
      sql.start_with?('SELECT "properties"."id"') && sql.include?('"properties"."firm_id" =')
    }

    expect(project_sql).to include('IN (SELECT "project_typologies"."project_id"')
    expect(project_sql).to include('"typologies"."category"')
    expect(project_sql).not_to include('FROM "projects" INNER JOIN "project_typologies"')
    expect(property_sql).to include('INNER JOIN "typologies"')
    expect(property_sql).to include('"typologies"."category"')
  end
end
