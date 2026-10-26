# frozen_string_literal: true

require "rails_helper"

RSpec.describe "LaunchIQ configuration rows", type: :request do
  let!(:city) { create(:city, name: "Mumbai", state: "Maharashtra") }

  before do
    Typology::CANONICAL.each do |row|
      Typology.upsert_canonical!(row, active_on_create: row[:category] == "residential")
    end
  end

  def ingest(units, code: "PRCAT001", pushed_at: "2026-10-20T12:00:00Z")
    Realtoriq::IngestProject.call(
      event: "upsert",
      pushed_at:,
      project_code: code,
      project_name: "Harbour One",
      developer_name: "Lodha",
      rera_number: "P51800000001",
      possession_on: "2027-12-31",
      city: "Mumbai",
      locality: "Worli",
      rm_name: "Asha Rao",
      rm_contact: "9876543210",
      unit_types: units
    )
  end

  def unit(typology_name, label, price: 10_000_000, **extra)
    { typology_name:, label:, price_min: price, typology_category: "residential" }.merge(extra)
  end

  # configuration, unit label, stored label, canonical name, flagged
  PAIRS = [
    [ "3BHK", "3 BHK", nil, "3 BHK", false ],
    [ "2BHK", "2 BHK", nil, "2 BHK", false ],
    [ "1BHK", "1 BHK", nil, "1 BHK", false ],
    [ "4BHK", "4 BHK", nil, "4 BHK", false ],
    [ "3BHK", "3 BHK ", nil, "3 BHK", false ],
    [ "1BHK", "1 BHK ", nil, "1 BHK", false ],
    [ "2BHK", "2 bhk", nil, "2 BHK", false ],
    [ "2BHK", "2 & 3 Bed Deck Residences", "2 & 3 Bed Deck Residences", "2 BHK", false ],
    [ "Commercial", "Grade A Boutique Office Spaces", "Grade A Boutique Office Spaces", "Office", false ],
    [ "3BHK Villa", "4.5 BHK", nil, "4.5 BHK", true ]
  ].freeze

  it "stores each production configuration and label pair" do
    PAIRS.each_with_index do |(configuration, label, stored, name, flagged), index|
      category = configuration == "Commercial" ? "commercial" : "residential"
      result = ingest(
        [ unit(configuration, label, typology_category: category) ],
        code: "PRPAIR#{index}"
      )
      row = result.project.project_typologies.sole

      expect(row.typology.name).to eq(name), "#{configuration} / #{label.inspect}"
      expect(row.label).to eq(stored), "#{configuration} / #{label.inspect}"
      expect(row.needs_review).to eq(flagged), "#{configuration} / #{label.inspect}"
    end
  end

  it "keeps two labels of one configuration and drops a repeated row" do
    result = ingest([
      unit("2BHK", "Ultima", price: 12_000_000),
      unit("2BHK", "Optima", price: 11_000_000),
      unit("2BHK", "2 BHK", price: 15_000_000),
      unit("2BHK", "2 bhk", price: 9_000_000)
    ])

    rows = result.project.project_typologies.sort_by { |row| row.label.to_s }
    expect(rows.map { |row| [ row.typology.name, row.label, row.starting_price ] }).to eq([
      [ "2 BHK", nil, 9_000_000 ],
      [ "2 BHK", "Optima", 11_000_000 ],
      [ "2 BHK", "Ultima", 12_000_000 ]
    ])
    expect(result.project.starting_budget).to eq(9_000_000)
  end

  it "keeps a variant that lives on the configuration name, and a tower label" do
    result = ingest([
      unit("2BHK Ultima", "2 BHK", price: 12_000_000),
      unit("2BHK", "Tower A Ultima", price: 13_000_000)
    ])

    rows = result.project.project_typologies.order(:label)
    expect(rows.map { |row| [ row.typology.name, row.label, row.needs_review ] }).to eq([
      [ "2 BHK", "2BHK Ultima", false ],
      [ "2 BHK", "Tower A Ultima", false ]
    ])
  end

  it "stores a plot's square metres and converts them with 10.7639" do
    result = ingest([
      unit("Plot", nil, price: 5_000_000, typology_category: "land", area_min: 15_000, area_unit: "sqm")
    ], code: "PRSQM001")
    row = result.project.project_typologies.sole

    expect(row.typology.code).to eq("residential_plot")
    expect(row.area_value).to eq(15_000)
    expect(row.area_unit).to eq("sqm")
    expect(row.starting_carpet_sqft).to eq(161_459)
    expect(row.review_note).to eq('LaunchIQ sent only "Plot". Confirm the plot type.')
  end

  it "stores a 2 BHK measured in square metres as 700 sq ft" do
    result = ingest([
      unit("2 BHK", nil, area_min: 65, area_unit: "sqm")
    ], code: "PRSQFT01")
    row = result.project.project_typologies.sole

    expect(row.typology.code).to eq("2_bhk")
    expect(row.area_value).to eq(700)
    expect(row.area_unit).to eq("sqft")
    expect(row.starting_carpet_sqft).to eq(700)
  end

  it "stores an office measured in square metres as sq ft" do
    result = ingest([
      unit("Office", nil, typology_category: "commercial", area_min: 120, area_unit: "sqm")
    ], code: "PRSQFT02")
    row = result.project.project_typologies.sole

    expect(row.typology.code).to eq("office")
    expect(row.area_unit).to eq("sqft")
    expect(row.area_value).to eq(AreaUnits.to_sqft(120, "sqm"))
    expect(row.starting_carpet_sqft).to eq(1_292)
  end

  it "writes a note for a BHK conflict, a bare plot, and an unknown unit" do
    conflict = ingest([ unit("3BHK Villa", "4.5 BHK") ], code: "PRNOTE1").project.project_typologies.sole
    expect(conflict.review_note).to eq(
      'LaunchIQ configuration "3BHK Villa" disagrees with unit label "4.5 BHK". ' \
      "Fix the unit in LaunchIQ, then push again."
    )

    plot = ingest([
      unit("Plot", nil, typology_category: "land", price: 5_000_000)
    ], code: "PRNOTE2").project.project_typologies.sole
    expect(plot.review_note).to eq('LaunchIQ sent only "Plot". Confirm the plot type.')

    unknown = ingest([
      unit("Hotel", nil, typology_category: nil, price: 5_000_000)
    ], code: "PRNOTE3").project.project_typologies.sole
    expect(unknown.review_note).to eq('Couldn\'t classify "Hotel" (LaunchIQ category: none).')
  end

  it "shows the review note, and a BHK conflict has no remap form" do
    note = 'LaunchIQ configuration "3BHK Villa" disagrees with unit label "4.5 BHK". ' \
      "Fix the unit in LaunchIQ, then push again."
    ingest([ unit("3BHK Villa", "4.5 BHK") ], code: "PRNOTE4")

    sign_in_admin
    get review_admin_masters_typologies_path

    expect(response.body).to include(ERB::Util.html_escape(note))
    expect(response.body).not_to include('name="project_typology_id"')
  end

  it "honours a review alias on the next push" do
    result = ingest([
      unit("Others", "Kiosk", price: 8_000_000, typology_category: "commercial")
    ], code: "PRKIOSK1")
    row = result.project.project_typologies.sole
    expect(row.typology.code).to eq("other_commercial")
    expect(row.label).to eq("Kiosk")
    expect(row.needs_review).to be(true)
    expect(row.review_note).to eq(
      'Couldn\'t classify "Others" (LaunchIQ category: commercial).'
    )

    sign_in_admin
    get review_admin_masters_typologies_path
    expect(response.body).to include("Kiosk")
    expect(response.body).to include(ERB::Util.html_escape(row.review_note))

    shop = Typology.find_by!(code: "shop")
    post remap_admin_masters_typologies_path, params: { project_typology_id: row.id, typology_id: shop.id }

    expect(row.reload.typology).to eq(shop)
    expect(row.needs_review).to be(false)
    expect(row.review_note).to be_nil
    expect(ConfigurationAlias.find_by!(key: "kiosk").source).to eq("review")

    again = ingest([
      unit("Others", "Kiosk", price: 8_000_000, typology_category: "commercial")
    ], code: "PRKIOSK1", pushed_at: "2026-10-21T12:00:00Z")
    stored = again.project.project_typologies.sole

    expect(stored.typology).to eq(shop)
    expect(stored.label).to eq("Kiosk")
    expect(stored.needs_review).to be(false)
  end
end
