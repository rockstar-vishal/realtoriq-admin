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
    listing = create(:property, firm:, city:, locality: kharghar, typology:, listing_for: "sale")

    result = import([ sale(property_codes: listing.code, location: nil, configurations: nil) ])

    lead = Lead.across_firms.find(result.results.first[:lead_id])
    expect(lead.lead_properties.map(&:property_id)).to eq([ listing.id ])
    expect(lead.locality_ids).to eq([ kharghar.id ])
    expect(lead.typology_ids).to eq([ typology.id ])
  end

  it "links a shared listing and takes the location from that firm's building" do
    other = create(:firm, status: :active)
    listing = Current.set(firm: other) do
      create(:property, firm: other, city:, locality: kharghar, typology:, listing_for: "sale", listed_on_marketplace: true)
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
    expect(result.results.first[:error]).to include("Possession is required")
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
      create(:property, firm: other, city:, locality: kharghar, building_name: "Quiet Tower", typology:,
        listing_for: "sale", listed_on_marketplace: true)
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

  it "reads Area and Prefers pre-leased, and rejects a mix of categories" do
    shop = create(:typology, name: "Shop", code: "shop", category: "commercial")
    plot = create(:typology, name: "Residential plot", code: "residential_plot", category: "land")

    commercial = import([
      sale(mobile: "9820155101", configurations: "Shop", area: "800-1200 sqft", prefers_pre_leased: "yes")
    ])
    residential = import([ sale(mobile: "9820155102", area: "800-1200 sqft") ])
    land = import([
      sale(mobile: "9820155103", configurations: "Residential plot", property_type: nil,
        area: "2-4 guntha", prefers_pre_leased: "yes")
    ])
    mixed = import([ sale(mobile: "9820155104", configurations: "2 BHK, Shop") ])
    occupied = import([ sale(mobile: "9820155101", configurations: "Shop") ])

    shop_lead = Lead.across_firms.find_by!(mobile: "+919820155101")
    plot_lead = Lead.across_firms.find_by!(mobile: "+919820155103")
    expect(commercial.created_count).to eq(1)
    expect(shop_lead.category).to eq("commercial")
    expect(shop_lead.typologies).to contain_exactly(shop)
    expect(shop_lead.area_min_sqft).to eq(800)
    expect(shop_lead.area_max_sqft).to eq(1_200)
    expect(shop_lead.prefers_pre_leased).to be(true)
    expect(residential.results.first[:error]).to include("Leave Area blank for a residential lead")
    expect(land.created_count).to eq(1)
    expect(plot_lead.category).to eq("land")
    expect(plot_lead.property_type).to be_nil
    expect(plot_lead.area_unit).to eq("guntha")
    expect(plot_lead.area_min_value).to eq(2)
    expect(plot_lead.area_max_value).to eq(4)
    expect(plot_lead.prefers_pre_leased).to be(false)
    expect(plot_lead.typologies).to contain_exactly(plot)
    expect(mixed.results.first[:error]).to eq("Configurations must be from one category.")
    expect(occupied.results.first[:error]).to eq(
      "A sale Commercial lead already exists for this number (#{shop_lead.code})."
    )
  end

  it "keeps Property type as an alias when the sheet still has a Possession date" do
    headers = [ "Name", "Mobile", "Sale or rent", "Property type", "Budget", "Configurations", "Location", "Possession" ]
    row = [ "Rhea Kapoor", "9820155111", "sale", "Under construction", "12000000", "2 BHK", "Kharghar, Mumbai", "31/12/2027" ]
    csv = CSV.generate { |sheet| sheet << headers; sheet << row }

    result = described_class.new(firm:, actor:, io: csv).call

    lead = Lead.across_firms.find(result.results.first[:lead_id])
    expect(lead.property_type.name).to eq("Under construction")
    expect(lead.possession_by).to eq(Date.new(2027, 12, 31))
  end

  it "rejects a possession type on a plot and requires one on a home" do
    create(:typology, name: "Residential plot", code: "residential_plot", category: "land")

    filled = import([ sale(configurations: "Residential plot", property_type: "Under construction") ])
    blank = import([ sale(mobile: "9820155121", property_type: nil) ])
    rented = import([
      sale(mobile: "9820155122", configurations: "Residential plot", transaction_type: "rent",
        property_type: nil, budget: "45000")
    ])

    expect(filled.results.first[:error]).to eq("Leave Possession blank for Plot & Land.")
    expect(blank.results.first[:error]).to include("Possession is required")
    expect(rented.results.first[:error]).to eq("Plot & Land is sale only.")
  end

  it "rejects a workbook and a semicolon file before creating anything" do
    workbook = described_class.new(firm:, actor:, io: "PK\x03\x04not really xlsx").call
    expect(workbook.file_error).to include("Excel workbook")

    semicolon = described_class.new(firm:, actor:, io: "Name;Mobile\nA;9820155001\n").call
    expect(semicolon.file_error).to include("semicolons")
    expect(Lead.across_firms.count).to eq(0)
  end

  it "imports a sheet written before the new columns existed" do
    headers = [ "Name", "Mobile", "Sale or rent", "Possession", "Budget", "Configurations", "Location" ]
    row = [ "Rhea Kapoor", "9820155201", "sale", "Under construction", "12000000", "2 BHK", "Kharghar, Mumbai" ]
    csv = CSV.generate { |sheet| sheet << headers; sheet << row }

    result = described_class.new(firm:, actor:, io: csv).call

    lead = Lead.across_firms.find(result.results.first[:lead_id])
    expect(result.created_count).to eq(1)
    expect(lead.assigned_user).to eq(actor)
    expect(lead.next_action_at).to be_nil
    expect(lead.near_label).to be_nil
  end

  it "names the new columns on a failed row" do
    result = import([ sale(budget: "nope") ])

    expect(result.results.first[:cells].keys).to eq(described_class::HEADERS.map(&:last))
  end

  it "tells the broker to replace the example rows, and still rejects a header with no rows" do
    sample = described_class.new(firm:, actor:, io: described_class.template).call
    header = CSV.generate { |sheet| sheet << described_class::HEADERS.map(&:last) }
    empty = described_class.new(firm:, actor:, io: header).call

    expect(sample.file_error).to eq(
      "The example rows were skipped. Replace Example lead with your own leads and import that file."
    )
    expect(empty.file_error).to eq("The file has no leads to import.")
    expect(Lead.across_firms.count).to eq(0)
  end

  it "imports the sample once the example name and mobile are replaced" do
    create(:property_type, name: "Ready possession")
    create(:typology, name: "Shop", code: "shop", category: "commercial")
    create(:typology, name: "Residential plot", code: "residential_plot", category: "land")
    create(:locality, city:, name: "Goregaon West")
    create(:locality, city:, name: "Panvel")
    %w[Referral Walk-in Website].each { |name| create(:lead_source, name:) }

    table = CSV.parse(described_class.template, headers: true)
    filled = CSV.generate do |sheet|
      sheet << table.headers
      table.each.with_index(1) do |row, index|
        row["Name"] = "Imported #{index}"
        row["Mobile"] = format("9820156%03d", index)
        sheet << row.fields
      end
    end

    result = described_class.new(firm:, actor:, io: filled).call

    expect(result.file_error).to be_nil
    expect(result.created_count).to eq(3)
    expect(result.failed_count).to eq(0)
    leads = result.results.map { |row| Lead.across_firms.find(row[:lead_id]) }
    expect(leads.map(&:category)).to eq(%w[residential commercial land])
    expect(leads.map { |lead| lead.assigned_user_id }.uniq).to eq([ actor.id ])
    expect(leads[0].next_action_at).to eq(Time.find_zone!("Asia/Kolkata").local(2026, 10, 28, 11, 0))
    expect(leads[0].lead_followups).to be_empty
    expect(leads[1].property_type.name).to eq("Ready possession")
    expect(leads[1].area_min_value).to eq(300)
    expect(leads[1].area_max_value).to eq(500)
    expect(leads[1].prefers_pre_leased).to be(true)
    expect(leads[1].lead_source.name).to eq("Walk-in")
    expect(leads[1].localities.map(&:name)).to include("Goregaon West")
    expect(leads[2].property_type).to be_nil
    expect(leads[2].area_unit).to eq("guntha")
    expect(leads[2].lead_source.name).to eq("Website")
    expect(leads[2].localities.map(&:name)).to include("Panvel")
  end

  it "assigns a teammate by mobile or email, and refuses someone else" do
    report = create(:user, firm:, role: :agent, name: "Neel Shah")
    create(:user_manager, user: report, manager: actor, firm:)
    retired = create(:user, :disabled, firm:, name: "Old Hand")

    result = import([
      sale(mobile: "9820155311", assigned_to: report.mobile),
      sale(mobile: "9820155312", assigned_to: report.email.upcase),
      sale(mobile: "9820155313", assigned_to: "9000011111"),
      sale(mobile: "9820155314", assigned_to: retired.mobile)
    ])

    assigned = Lead.across_firms.order(:code).to_a
    expect(result.created_count).to eq(2)
    expect(assigned.map(&:assigned_user)).to eq([ report, report ])
    expect(result.results[2][:error]).to eq("No active team member has 9000011111.")
    expect(result.results[3][:error]).to eq("Old Hand is disabled. Assign someone else or leave it blank.")
  end

  it "lets an agent keep a lead and refuses a manager's number" do
    agent = create(:user, firm:, role: :agent)
    csv = csv_for([
      sale(mobile: "9820155321", assigned_to: actor.mobile),
      sale(mobile: "9820155322", assigned_to: agent.email)
    ])

    result = described_class.new(firm:, actor: agent, io: csv).call

    expect(result.results[0][:error]).to eq("Only a manager can assign leads to someone else.")
    expect(result.created_count).to eq(1)
    expect(Lead.across_firms.find_by!(mobile: "+919820155322").assigned_user).to eq(agent)
  end

  it "reads a next call in IST, including a date with no time, and a note" do
    zone = Time.find_zone!("Asia/Kolkata")
    result = import([
      sale(mobile: "9820155331", next_call: "01/01/2020 09:30"),
      sale(mobile: "9820155332", next_call: "15/02/2026"),
      sale(mobile: "9820155333", next_call: "28/10/2026 11:00", next_call_note: "Call after lunch"),
      sale(mobile: "9820155334", next_call: "28 Oct 2026"),
      sale(mobile: "9820155335", next_call_note: "No date")
    ])

    past = Lead.across_firms.find_by!(mobile: "+919820155331")
    midday = Lead.across_firms.find_by!(mobile: "+919820155332")
    noted = Lead.across_firms.find_by!(mobile: "+919820155333")
    expect(past.next_action_at).to eq(zone.local(2020, 1, 1, 9, 30))
    expect(past.lead_followups).to be_empty
    expect(midday.next_action_at).to eq(zone.local(2026, 2, 15, 11, 0))
    expect(noted.next_action_at).to eq(zone.local(2026, 10, 28, 11, 0))
    expect(noted.lead_followups.sole.comment).to eq("Call after lunch")
    expect(result.results[3][:error]).to eq(described_class::NEXT_CALL_FORMAT)
    expect(result.results[4][:error]).to eq("Add a Next call, or leave the note blank.")
  end

  it "rejects a next call on a day that month does not have" do
    result = import([
      sale(mobile: "9820155361", next_call: "31/02/2026"),
      sale(mobile: "9820155362", next_call: "31/04/2026 11:00"),
      sale(mobile: "9820155363", next_call: "29/02/2026")
    ])

    expect(result.created_count).to eq(0)
    expect(result.results.map { |row| row[:error] }).to all(eq(described_class::NEXT_CALL_FORMAT))
  end

  it "reads a pin as coordinates or a full Maps link, and rejects a short link" do
    result = import([
      sale(mobile: "9820155341", near_place: "Office", near_place_pin: "19.076, 72.8777"),
      sale(mobile: "9820155342", near_place: "Home", near_place_pin: "https://www.google.com/maps/@19.1,72.8,15z"),
      sale(mobile: "9820155343", near_place: "Site", near_place_pin: "https://maps.google.com/?q=19.2,72.9"),
      sale(mobile: "9820155344", near_place: "Gate", near_place_pin: "https://www.google.com/maps/search/?api=1&query=19.3%2C72.85"),
      sale(mobile: "9820155345", near_place: "Office", near_place_pin: "https://maps.app.goo.gl/abc"),
      sale(mobile: "9820155346", near_place: "Office", near_place_pin: "https://goo.gl/maps/abc"),
      sale(mobile: "9820155347", near_place: "Office"),
      sale(mobile: "9820155348", near_place_pin: "19.076,72.8777"),
      sale(mobile: "9820155349", near_place: "A" * 41, near_place_pin: "19.076,72.8777"),
      sale(mobile: "9820155350", near_place: "Office", near_place_pin: "1,1")
    ])

    office = Lead.across_firms.find_by!(mobile: "+919820155341")
    home = Lead.across_firms.find_by!(mobile: "+919820155342")
    site = Lead.across_firms.find_by!(mobile: "+919820155343")
    gate = Lead.across_firms.find_by!(mobile: "+919820155344")
    expect(result.created_count).to eq(4)
    expect(office.near_label).to eq("Office")
    expect(office.near_address).to be_nil
    expect(office.near_lat).to eq(BigDecimal("19.076"))
    expect(office.near_lng).to eq(BigDecimal("72.8777"))
    expect(home.near_lat).to eq(BigDecimal("19.1"))
    expect(site.near_lng).to eq(BigDecimal("72.9"))
    expect(gate.near_lat).to eq(BigDecimal("19.3"))
    expect(gate.near_lng).to eq(BigDecimal("72.85"))
    expect(result.results[4][:error]).to eq(described_class::SHORT_PIN)
    expect(result.results[5][:error]).to eq(described_class::SHORT_PIN)
    expect(result.results[6][:error]).to eq("Near place needs both a name and a pin.")
    expect(result.results[7][:error]).to eq("Near place needs both a name and a pin.")
    expect(result.results[8][:error]).to eq("Near label is too long (maximum is 40 characters)")
    expect(result.results[9][:error]).to eq("The place must be inside India.")
  end
end
