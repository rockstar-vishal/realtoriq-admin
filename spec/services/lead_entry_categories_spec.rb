# frozen_string_literal: true

require "rails_helper"

RSpec.describe "lead entry categories" do
  let(:firm) { create(:firm, status: :active) }
  let!(:owner) { create(:user, :super_admin, firm:) }
  let!(:status) { create(:lead_status, :new_lead) }
  let!(:under_construction) { create(:property_type, name: "Under construction") }
  let!(:ready) { create(:property_type, name: "Ready possession") }
  let!(:home) { create(:typology, name: "2 BHK", code: "2_bhk") }
  let!(:shop) { create(:typology, name: "Shop", code: "shop", category: "commercial") }
  let!(:plot) { create(:typology, name: "Residential plot", code: "residential_plot", category: "land") }
  let!(:city) { create(:city, name: "Mumbai", state: "Maharashtra") }
  let!(:locality) { create(:locality, city:, name: "Kharghar") }
  let!(:website_source) { create(:lead_source, name: "Website", category: "other") }
  let!(:meta_source) { create(:lead_source, name: "Social / Meta", category: "social") }
  let!(:microsite_source) { create(:lead_source, name: "Builder Microsite", category: "other") }
  let!(:site_source) { create(:lead_source, name: "Broker website", category: "other") }

  def residential_lead(mobile)
    create(:lead, firm:, lead_status: status, mobile:, transaction_type: "sale",
      property_type: under_construction, category: "residential").tap do |lead|
      lead.typologies << home
      lead.localities << locality
    end
  end

  describe "Facebook" do
    before { Current.firm = firm }

    let!(:project) do
      create(:project, firm:, city:, locality:, starting_budget: 12_000_000).tap do |record|
        create(:project_typology, project: record, typology: home)
        create(:project_typology, project: record, typology: shop, starting_price: 4_000_000)
      end
    end
    let!(:page) do
      connection = create(:facebook_connection, firm:, connected_by_user: owner)
      create(:facebook_page, firm:, facebook_connection: connection)
    end
    let!(:form) { create(:facebook_lead_form, firm:, facebook_page: page, project:, category: "commercial") }

    def import_lead(mobile)
      Facebook::LeadImporter.call(
        import: create(:facebook_lead_import, firm:, facebook_page: form.facebook_page),
        form:,
        payload: {
          "field_data" => [
            { "name" => "full_name", "values" => [ "Rhea Kapoor" ] },
            { "name" => "phone_number", "values" => [ mobile ] }
          ]
        }
      )
    end

    it "does not create a city named on the form" do
      form.update!(field_mappings: { "full_name" => "name", "phone_number" => "mobile", "city" => "notes" })

      expect {
        created = Facebook::LeadImporter.call(
          import: create(:facebook_lead_import, firm:, facebook_page: form.facebook_page),
          form:,
          payload: {
            "field_data" => [
              { "name" => "full_name", "values" => [ "Rhea Kapoor" ] },
              { "name" => "phone_number", "values" => [ "9876500188" ] },
              { "name" => "city", "values" => [ "Ahmedabad" ] }
            ]
          }
        )
        expect(created.status).to eq(:created), created.error.to_s
      }.not_to change(City, :count)
      expect(City.where("LOWER(name) = ?", "ahmedabad")).to be_none
    end

    it "uses the form category on a mixed project and ignores another category" do
      residential_lead("9876500100")

      created = import_lead("9876500100")
      duplicate = import_lead("9876500100")

      expect(created.status).to eq(:created), created.error.to_s
      expect(created.lead.category).to eq("commercial")
      expect(created.lead.typologies).to contain_exactly(shop)
      expect(created.lead.property_type).to eq(under_construction)
      expect(duplicate.status).to eq(:duplicate)
      expect(duplicate.lead).to eq(created.lead)
      expect(Lead.unscoped.where(firm:, mobile: "+919876500100").count).to eq(2)
    end

    it "falls back to the project's primary category when the form category is no longer offered" do
      form.update_columns(category: "land")

      created = import_lead("9876500199")

      expect(created.status).to eq(:created), created.error.to_s
      expect(created.lead.category).to eq("residential")
      expect(created.lead.typologies).to contain_exactly(home)
    end

    it "takes a property's category and skips possession on a plot" do
      property = create(:property, firm:, city:, locality:, typology: plot, listing_for: "sale", price: 5_000_000)
      property_form = create(:facebook_lead_form, firm:, facebook_page: page, property:)

      result = Facebook::LeadImporter.call(
        import: create(:facebook_lead_import, firm:, facebook_page: property_form.facebook_page),
        form: property_form,
        payload: {
          "field_data" => [
            { "name" => "full_name", "values" => [ "Rhea Kapoor" ] },
            { "name" => "phone_number", "values" => [ "9876500101" ] }
          ]
        }
      )

      expect(result.status).to eq(:created)
      expect(result.lead.category).to eq("land")
      expect(result.lead.property_type).to be_nil
      expect(result.lead.typologies).to contain_exactly(plot)
    end
  end

  describe "inbound" do
    let!(:project) do
      create(:project, firm:, city:, locality:, name: "Lodha Palava", starting_budget: 14_200_000).tap do |record|
        create(:project_typology, project: record, typology: home)
        create(:project_typology, project: record, typology: shop, starting_price: 4_000_000)
      end
    end

    it "copies the project's primary category and still accepts another category" do
      create(:lead, firm:, lead_status: status, mobile: "+919876500200", transaction_type: "sale",
        property_type: under_construction, category: "commercial").tap { |lead| lead.typologies << shop }

      result = Inbound::ReceiveLead.call(
        firm:, channel: "general", kind: "projects",
        payload: { "name" => "Rahul Sharma", "mobile" => "9876500200", "listing" => project.code }
      )

      expect(result).to be_ok
      expect(result.status).to eq("created")
      expect(result.lead.category).to eq("residential")
      expect(result.lead.typologies).to contain_exactly(home)
      expect(result.lead.lead_source).to eq(website_source)
    end

    it "rejects an unlisted plot asked as rent and saves a plot sale without possession" do
      rented = Inbound::ReceiveLead.call(
        firm:, channel: "general", kind: "properties",
        payload: {
          "name" => "Rahul Sharma", "mobile" => "9876500201", "budget" => "5000000",
          "city" => "Mumbai", "locality" => "Kharghar", "configuration" => "Residential plot",
          "transaction_type" => "rent"
        }
      )
      sold = Inbound::ReceiveLead.call(
        firm:, channel: "general", kind: "projects",
        payload: {
          "name" => "Rahul Sharma", "mobile" => "9876500202", "budget" => "5000000",
          "city" => "Mumbai", "locality" => "Kharghar", "configuration" => "Residential plot"
        }
      )

      expect(rented).not_to be_ok
      expect(rented.error).to eq("Plot & Land is sale only.")
      expect(sold).to be_ok
      expect(sold.lead.category).to eq("land")
      expect(sold.lead.transaction_type).to eq("sale")
      expect(sold.lead.property_type).to be_nil
    end

    it "tells the caller that land is sale only and names Shop, Office and Residential plot" do
      credential = InboundCredential.issue!(firm)
      text = Inbound::Instructions.payload(credential, "https://example.test")[:portals]
        .map { |row| row[:message].gsub(credential.token, "[token]") }
        .join("\n")

      expect(text).to include("Shop")
      expect(text).to include("Office")
      expect(text).to include("Residential plot")
      expect(text).to include("Plot & Land is sale only")
    end
  end

  describe "microsite" do
    let!(:catalog) do
      create(:project, :catalog, firm: nil, city:, locality:, external_ref: "PRMIC001",
        starting_budget: 8_000_000, name: "Market Shop")
    end
    let!(:link) do
      create(:project_typology, project: catalog, typology: shop, starting_price: 8_000_000)
      Current.firm = firm
      ProjectShareLink.create!(firm:, user: owner, project: catalog)
    end

    def enquire(phone, enquiry_id: SecureRandom.uuid)
      Realtoriq::ReceiveEnquiry.call(
        event: "enquiry",
        pushed_at: Time.current.utc.iso8601,
        submitted_at: Time.current.utc.iso8601,
        enquiry_id:,
        project_code: "PRMIC001",
        share_token: link.token,
        name: "Meera Shah",
        phone:
      )
    end

    it "uses the project category and does not treat another category as the same lead" do
      residential_lead("9876500300")

      first = enquire("9876500300")
      second = enquire("9876500300")

      expect(first).to be_ok
      expect(second).to be_ok
      leads = Lead.unscoped.where(firm:, mobile: "+919876500300")
      expect(leads.map(&:category)).to contain_exactly("residential", "commercial")
      commercial = leads.find_by!(category: "commercial")
      expect(commercial.typologies).to contain_exactly(shop)
      expect(commercial.property_type).to eq(under_construction)
      expect(commercial.lead_source).to eq(microsite_source)
    end
  end

  describe "broker website" do
    let!(:project) do
      create(:project, firm:, city:, locality:, starting_budget: 9_000_000, on_website: true).tap do |record|
        create(:project_typology, project: record, typology: shop, starting_price: 9_000_000)
      end
    end

    def enquire(mobile, listing: project)
      Sites::ReceiveEnquiry.call(
        firm:, name: "Rhea Kapoor", mobile:, message: "Please call",
        listing_kind: "project", listing_code: listing.code
      )
    end

    it "uses the project category and does not treat another category as the same lead" do
      residential_lead("9876500400")

      expect(enquire("9876500400")).to be_ok
      expect(enquire("9876500400")).to be_ok

      leads = Lead.unscoped.where(firm:, mobile: "+919876500400")
      expect(leads.map(&:category)).to contain_exactly("residential", "commercial")
      expect(leads.find_by!(category: "commercial").lead_source).to eq(site_source)
    end

    it "saves a plot enquiry without a possession type" do
      land = create(:project, firm:, city:, locality:, starting_budget: 4_000_000, on_website: true)
      create(:project_typology, project: land, typology: plot, starting_price: 4_000_000)

      expect(enquire("9876500401", listing: land)).to be_ok

      lead = Lead.unscoped.find_by!(firm:, mobile: "+919876500401")
      expect(lead.category).to eq("land")
      expect(lead.property_type).to be_nil
      expect(lead.typologies).to contain_exactly(plot)
    end
  end

  describe "telecalling" do
    let(:actor) { create(:user, :manager, firm:) }
    let(:prospect) { create(:prospect, firm:, mobile: "+919876500500") }

    before { Current.firm = firm }
    after { Current.reset }

    it "defaults a project to its primary category and copies only that category" do
      project = create(:project, firm:, city:, locality:, starting_budget: 12_000_000)
      create(:project_typology, project:, typology: home)
      create(:project_typology, project:, typology: shop, starting_price: 4_000_000)

      result = Prospects::Convert.new(
        prospect:, actor:, notes: "Interested",
        lead: { mode: "project", project_id: project.id, property_type_id: under_construction.id }
      ).call

      expect(result).to be_ok
      expect(result.prospect.lead.category).to eq("residential")
      expect(result.prospect.lead.typologies).to contain_exactly(home)
    end

    it "uses a chosen project category, the property's category, and requirement area" do
      project = create(:project, firm:, city:, locality:, starting_budget: 12_000_000)
      create(:project_typology, project:, typology: home)
      create(:project_typology, project:, typology: shop, starting_price: 4_000_000)
      property = create(:property, firm:, city:, locality:, typology: shop, listing_for: "sale", price: 6_000_000)
      caller = create(:prospect, firm:, mobile: "+919876500501")
      buyer = create(:prospect, firm:, mobile: "+919876500502")

      chosen = Prospects::Convert.new(
        prospect:, actor:, notes: "Shop",
        lead: {
          mode: "project", project_id: project.id, category: "commercial",
          property_type_id: under_construction.id
        }
      ).call
      from_property = Prospects::Convert.new(
        prospect: caller, actor:, notes: "This shop",
        lead: { mode: "property", property_id: property.id, property_type_id: ready.id }
      ).call
      from_requirements = Prospects::Convert.new(
        prospect: buyer, actor:, notes: "Area",
        lead: {
          mode: "requirements", transaction_type: "sale", property_type_id: under_construction.id,
          budget: 5_000_000, typology_ids: [ shop.id ], locality_ids: [ locality.id ],
          area_min: 800, area_max: 1200, area_unit: "sqft", prefers_pre_leased: true
        }
      ).call

      expect(chosen.prospect.lead.category).to eq("commercial")
      expect(chosen.prospect.lead.typologies).to contain_exactly(shop)
      expect(from_property.prospect.lead.category).to eq("commercial")
      expect(from_property.prospect.lead.typologies).to contain_exactly(shop)
      expect(from_requirements.prospect.lead.category).to eq("commercial")
      expect(from_requirements.prospect.lead.area_min_sqft).to eq(800)
      expect(from_requirements.prospect.lead.area_max_sqft).to eq(1200)
      expect(from_requirements.prospect.lead.prefers_pre_leased).to be(true)
    end
  end
end
