# frozen_string_literal: true

require "rails_helper"

RSpec.describe Leads::Import do
  let(:firm) { create(:firm, status: :active) }
  let(:actor) { create(:user, :manager, firm:) }
  let(:builder) { create(:builder) }
  let!(:status) { create(:lead_status, :new_lead) }
  let!(:property_type) { create(:property_type, name: "Under construction") }
  let!(:typology) { create(:typology, name: "2 BHK") }
  let!(:city) { create(:city, name: "Mumbai", state: "Maharashtra") }
  let!(:kharghar) { create(:locality, city:, name: "Kharghar") }
  let!(:worli) { create(:locality, city:, name: "Worli") }
  let!(:project) do
    create(:project, firm:, builder:, city:, locality: worli).tap do |record|
      create(:project_typology, project: record, typology:)
    end
  end

  before { Current.firm = firm }
  after { Current.reset }

  def csv_for(rows)
    CSV.generate do |csv|
      csv << described_class::HEADERS.map(&:last)
      rows.each { |values| csv << described_class::HEADERS.map { |key, _name| values[key] } }
    end
  end

  def import(rows)
    described_class.new(firm:, actor:, io: csv_for(rows)).call
  end

  def sale(**values)
    {
      name: "Rhea Kapoor", mobile: "9820155001", transaction_type: "sale",
      property_type: "Under construction", budget: "12000000",
      configurations: "2 BHK", location: "Kharghar, Mumbai"
    }.merge(values)
  end

  it "creates a lead, skips the sample row, and leaves a bad code uncreated" do
    sample = sale(name: "Example lead", mobile: "9000000000")
    good = sale(mobile: "9820155001", project_codes: project.code, location: nil, configurations: nil)
    bad = sale(mobile: "9820155002", project_codes: "P-ZZZZZZ")

    result = import([ sample, good, bad ])

    expect(result.file_error).to be_nil
    expect(result.created_count).to eq(1)
    expect(result.failed_count).to eq(1)
    lead = Lead.across_firms.find(result.results.first[:lead_id])
    expect(lead.code).to eq("L-0001")
    expect(lead.assigned_user).to eq(actor)
    expect(lead.lead_status).to eq(status)
    expect(lead.locality_ids).to eq([ worli.id ])
    expect(lead.typology_ids).to eq([ typology.id ])
    expect(lead.lead_projects.map(&:project_id)).to eq([ project.id ])
    expect(result.results.last[:error]).to include("Unknown project code")
    expect(result.results.last[:cells]["Mobile"]).to eq("9820155002")
    expect(Lead.across_firms.where(mobile: "+919820155002")).to be_empty
  end

  it "links a property and uses the building locality when Location is blank" do
    building = create(:building, firm:, city:, locality: kharghar)
    listing = create(:property, firm:, building:, typology:, listing_for: "sale")

    result = import([ sale(property_codes: listing.code, location: nil, configurations: nil) ])

    lead = Lead.across_firms.find(result.results.first[:lead_id])
    expect(lead.lead_properties.map(&:property_id)).to eq([ listing.id ])
    expect(lead.locality_ids).to eq([ kharghar.id ])
    expect(lead.typology_ids).to eq([ typology.id ])
  end

  it "links a shared listing and takes the location from that firm's building" do
    other = create(:firm, status: :active)
    listing = Current.set(firm: other) do
      building = create(:building, firm: other, city:, locality: kharghar)
      create(:property, firm: other, building:, typology:, listing_for: "sale", listed_on_marketplace: true)
    end

    result = import([ sale(property_codes: listing.code, location: nil, configurations: nil) ])

    expect(result.created_count).to eq(1)
    lead = Lead.across_firms.find(result.results.first[:lead_id])
    expect(lead.locality_ids).to eq([ kharghar.id ])
    expect(lead.lead_properties.map(&:property_id)).to eq([ listing.id ])
  end

  it "adds a typed location to the localities on the linked project" do
    result = import([ sale(project_codes: project.code, location: "Kharghar, Mumbai") ])

    lead = Lead.across_firms.find(result.results.first[:lead_id])
    expect(lead.locality_ids).to contain_exactly(worli.id, kharghar.id)
  end

  it "refuses a rent row that names a project and still imports the next row" do
    result = import([
      sale(mobile: "9820155011", transaction_type: "rent", property_type: nil, project_codes: project.code, budget: "45000"),
      sale(mobile: "9820155012")
    ])

    expect(result.created_count).to eq(1)
    expect(result.results.first[:error]).to include("sale lead")
    expect(Lead.across_firms.find_by(mobile: "+919820155011")).to be_nil
  end

  it "requires a property type on a sale row even when a project code is present" do
    result = import([ sale(property_type: nil, project_codes: project.code) ])

    expect(result.created_count).to eq(0)
    expect(result.results.first[:error]).to include("Property type is required")
  end

  it "names a duplicate the caller can see, and hides the code when they cannot" do
    import([ sale(mobile: "9820155021") ])
    existing = Lead.across_firms.find_by!(mobile: "+919820155021")

    again = import([ sale(mobile: "9820155021") ])
    expect(again.results.first[:error]).to include(existing.code)

    agent = create(:user, firm:, role: :agent)
    hidden = described_class.new(firm:, actor: agent, io: csv_for([ sale(mobile: "9820155021") ])).call
    expect(hidden.results.first[:error]).to include("already exists")
    expect(hidden.results.first[:error]).not_to include(existing.code)
  end

  it "refuses a mobile Excel saved as a scientific number" do
    result = import([ sale(mobile: "9.82016E+09") ])

    expect(result.results.first[:error]).to include("Format the Mobile column as Text")
    expect(result.created_count).to eq(0)
  end

  it "reports a suspended firm's property code as unknown and does not reveal it" do
    other = create(:firm, :suspended, name: "Quiet Estates")
    listing = Current.set(firm: other) do
      building = create(:building, firm: other, city:, locality: kharghar, name: "Quiet Tower")
      create(:property, firm: other, building:, typology:, listing_for: "sale", listed_on_marketplace: true)
    end

    by_code = import([ sale(property_codes: listing.code) ])
    by_id = import([ sale(mobile: "9820155031", project_codes: listing.id) ])

    expect(by_code.created_count).to eq(0)
    expect(by_code.results.first[:error]).to include("Unknown property code")
    expect(by_code.results.first[:error]).not_to include("Quiet Estates", "Quiet Tower")
    expect(by_id.results.first[:error]).to include("Unknown project code")
    expect(by_id.results.first[:error]).not_to include(listing.code)
    expect(Lead.across_firms.count).to eq(0)
  end

  it "refuses a cell with more than 20 codes before creating the lead" do
    codes = Array.new(21) { |index| "P-#{format('%06d', index)}" }

    result = import([ sale(project_codes: codes.join(", ")) ])

    expect(result.created_count).to eq(0)
    expect(result.results.first[:error]).to include("at most 20")
    expect(Lead.across_firms.count).to eq(0)
  end

  it "does not import another firm's private project code" do
    other = create(:firm, status: :active)
    secret = nil
    Current.set(firm: other) do
      secret = create(:project, firm: other, builder:, city:, locality: worli)
    end

    result = import([ sale(project_codes: secret.code, location: nil, configurations: nil) ])

    expect(result.created_count).to eq(0)
    expect(result.results.first[:error]).to include("Unknown project code")
    expect(result.results.first[:error]).not_to include(secret.name)
  end

  it "rejects a workbook and a semicolon file before creating anything" do
    workbook = described_class.new(firm:, actor:, io: "PK\x03\x04not really xlsx").call
    expect(workbook.file_error).to include("Excel workbook")

    semicolon = described_class.new(firm:, actor:, io: "Name;Mobile\nA;9820155001\n").call
    expect(semicolon.file_error).to include("semicolons")
    expect(Lead.across_firms.count).to eq(0)
  end
end
