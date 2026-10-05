# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API v1 inbound leads" do
  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, status: :active) }
  let!(:owner) { create(:user, :super_admin, firm:) }
  let!(:credential) { InboundCredential.issue!(firm) }
  let(:token) { credential.token }

  let!(:new_status) { create(:lead_status, :new_lead) }
  let!(:under_construction) { create(:property_type, name: "Under construction") }
  let!(:ready_possession) { create(:property_type, name: "Ready possession") }
  let!(:source_99acres) { create(:lead_source, name: "Portal — 99acres", category: "portal") }
  let!(:source_magicbricks) { create(:lead_source, name: "Portal — Magicbricks", category: "portal") }
  let!(:source_housing) { create(:lead_source, name: "Portal — Housing", category: "portal") }
  let!(:source_website) { create(:lead_source, name: "Website", category: "other") }

  let(:city) { create(:city, name: "Mumbai") }
  let(:locality) { create(:locality, city:, name: "Kharghar") }
  let(:typology) { create(:typology, name: "2 BHK") }
  let(:project) do
    create(:project, firm:, name: "Lodha Palava", city:, locality:,
      starting_budget: 14_200_000, possession_on: 18.months.from_now.to_date, possession_label: nil)
  end

  def post_inbound(channel, kind, body, key: token)
    post "/api/v1/inbound/#{channel}/#{kind}",
      params: body, headers: { "Authorization" => "Bearer #{key}" }, as: :json
  end

  def buyer(extra = {})
    { name: "Rahul Sharma", mobile: "9876543210" }.merge(extra)
  end

  def leads
    Lead.across_firms.where(firm:)
  end

  before do
    create(:project_typology, project:, typology:)
  end

  it "rejects a bad key and does not tell the firm" do
    expect {
      post_inbound("99acres", "projects", buyer(listing: project.code), key: "not-a-key")
    }.not_to change { Notification.across_firms.count }

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body.dig("error", "code")).to eq("unauthorized")
  end

  it "rejects an unknown portal after a valid key" do
    post_inbound("nope", "projects", buyer(listing: project.code))

    expect(response).to have_http_status(:not_found)
  end

  it "creates a sale lead from a project code and copies the listing" do
    post_inbound("magicbricks", "projects", buyer(listing: project.code.downcase, budget: 1, transaction_type: "rent"))

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["status"]).to eq("created")
    lead = leads.find_by(mobile: "+919876543210")
    expect(lead.transaction_type).to eq("sale")
    expect(lead.property_type).to eq(under_construction)
    expect(lead.budget_max).to eq(14_200_000)
    expect(lead.lead_source).to eq(source_magicbricks)
    expect(lead.assigned_user_id).to be_nil
    expect(lead.typologies).to contain_exactly(typology)
    expect(lead.localities).to contain_exactly(locality)
    expect(lead.lead_projects.map(&:project_id)).to contain_exactly(project.id)
  end

  it "finds a project by its saved portal code and not from another portal" do
    project.update!(portal_99acres_code: "ACME-22")

    post_inbound("magicbricks", "projects", buyer(listing: "ACME-22"))
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "message")).to eq("We could not find this project.")

    post_inbound("99acres", "projects", buyer(listing: "acme-22"))
    expect(response).to have_http_status(:ok)
    expect(leads.find_by(mobile: "+919876543210").lead_projects.map(&:project_id)).to eq([ project.id ])
  end

  it "finds a project by its exact name" do
    post_inbound("housing", "projects", buyer(listing: "lodha   palava"))

    expect(response).to have_http_status(:ok)
    expect(leads.find_by(mobile: "+919876543210").lead_projects.map(&:project_id)).to eq([ project.id ])
  end

  it "does not match another firm's project or a marketplace project" do
    other = create(:project, name: "Other Firm", city:, locality:)
    create(:project_typology, project: other, typology:)
    catalog = create(:project, :catalog, firm: nil, name: "Catalog One", city:, external_ref: "launchiq-inbound")

    post_inbound("99acres", "projects", buyer(listing: other.code))
    expect(response).to have_http_status(:unprocessable_content)

    post_inbound("99acres", "projects", buyer(listing: catalog.code, mobile: "9876543211"))
    expect(response).to have_http_status(:unprocessable_content)
    expect(leads.count).to eq(0)
  end

  it "marks a project Ready only from the exact label or a near possession month" do
    today = Time.find_zone("Asia/Kolkata").today
    project.update!(possession_on: nil, possession_label: "Ready")
    post_inbound("99acres", "projects", buyer(listing: project.code))
    expect(leads.find_by(mobile: "+919876543210").property_type).to eq(ready_possession)

    project.update!(possession_on: today, possession_label: nil)
    post_inbound("99acres", "projects", buyer(listing: project.code, mobile: "9876543211"))
    expect(leads.find_by(mobile: "+919876543211").property_type).to eq(ready_possession)

    project.update!(possession_on: today - 2.months, possession_label: nil)
    post_inbound("99acres", "projects", buyer(listing: project.code, mobile: "9876543212"))
    expect(leads.find_by(mobile: "+919876543212").property_type).to eq(under_construction)

    project.update!(possession_on: nil, possession_label: "Ready to move")
    post_inbound("99acres", "projects", buyer(listing: project.code, mobile: "9876543213"))
    expect(leads.find_by(mobile: "+919876543213").property_type).to eq(under_construction)
  end

  it "saves a project with no locality and rejects one with no configuration" do
    project.update!(locality: nil)
    post_inbound("99acres", "projects", buyer(listing: project.code))
    expect(response).to have_http_status(:ok)
    expect(leads.find_by(mobile: "+919876543210").localities).to be_empty

    bare = create(:project, firm:, name: "Bare Project", city:, locality:)
    expect {
      post_inbound("99acres", "projects", buyer(listing: bare.code, mobile: "9876543214"))
    }.to change { Notification.across_firms.where(user: owner, kind: "inbound_enquiry").count }.by(1)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "message")).to include("no configuration")
  end

  it "requires budget, city, locality and configuration when a project is omitted" do
    post_inbound("99acres", "projects", buyer)
    expect(response).to have_http_status(:unprocessable_content)

    post_inbound("general", "projects", buyer(
      budget: "12000000", city: "Mumbai", locality: "Kharghar", configuration: "2 BHK",
      transaction_type: "rent"
    ))
    expect(response).to have_http_status(:ok)
    lead = leads.find_by(mobile: "+919876543210")
    expect(lead.transaction_type).to eq("sale")
    expect(lead.property_type).to eq(under_construction)
    expect(lead.budget_max).to eq(12_000_000)
    expect(lead.lead_source).to eq(source_website)
    expect(lead.lead_projects).to be_empty
  end

  it "refuses to guess when two cities share a name" do
    create(:city, name: "Aurangabad", state: "Maharashtra")
    create(:city, name: "Aurangabad", state: "Bihar")

    post_inbound("general", "projects", buyer(
      budget: "12000000", city: "Aurangabad", locality: "Kharghar", configuration: "2 BHK"
    ))
    expect(response.parsed_body.dig("error", "message")).to eq("More than one city is named Aurangabad.")
  end

  it "reads sale or rent from the property and ignores the body" do
    sale = create(:property, firm:, typology:, price: 11_800_000, listing_for: "sale", status: "booked")
    rent = create(:property, firm:, typology:, price: 45_000, listing_for: "rent")

    post_inbound("housing", "properties", buyer(listing: sale.code, transaction_type: "rent"))
    expect(response).to have_http_status(:ok)
    sale_lead = leads.find_by(mobile: "+919876543210")
    expect(sale_lead.transaction_type).to eq("sale")
    expect(sale_lead.property_type).to eq(ready_possession)
    expect(sale_lead.budget_max).to eq(11_800_000)
    expect(sale_lead.lead_properties.map(&:property_id)).to eq([ sale.id ])

    post_inbound("housing", "properties", buyer(listing: rent.code, mobile: "9876543211", transaction_type: "sale"))
    rent_lead = leads.find_by(mobile: "+919876543211")
    expect(rent_lead.transaction_type).to eq("rent")
    expect(rent_lead.property_type).to be_nil
    expect(rent_lead.lead_properties.map(&:property_id)).to eq([ rent.id ])
  end

  it "finds a property by its saved code and rejects a portal call with no listing" do
    property = create(:property, firm:, typology:, portal_magicbricks_code: "MB-9")

    post_inbound("99acres", "properties", buyer(listing: "MB-9"))
    expect(response).to have_http_status(:unprocessable_content)

    post_inbound("magicbricks", "properties", buyer(listing: "mb-9"))
    expect(response).to have_http_status(:ok)
    expect(leads.find_by(mobile: "+919876543210").lead_properties.map(&:property_id)).to eq([ property.id ])

    expect {
      post_inbound("housing", "properties", buyer(mobile: "9876543215"))
    }.to change { Notification.across_firms.where(user: owner, kind: "inbound_enquiry").count }.by(1)
    expect(response.parsed_body.dig("error", "message")).to eq("Send the listing code saved on the property.")

    expect {
      post_inbound("housing", "properties", buyer(mobile: "9876543215"))
    }.not_to change { Notification.across_firms.where(user: owner, kind: "inbound_enquiry").count }
  end

  it "lets the general property URL omit the listing when sale or rent is sent" do
    post_inbound("general", "properties", buyer(
      budget: "45000", city: "Mumbai", locality: "Kharghar", configuration: "2 bhk", transaction_type: "rent"
    ))
    expect(response).to have_http_status(:ok)
    lead = leads.find_by(mobile: "+919876543210")
    expect(lead.transaction_type).to eq("rent")
    expect(lead.property_type).to be_nil
    expect(lead.budget_max).to eq(45_000)

    post_inbound("general", "properties", buyer(mobile: "9876543216", budget: "9000000", city: "Mumbai",
      locality: "Kharghar", configuration: "2 BHK"))
    expect(response.parsed_body.dig("error", "message")).to eq("Say whether this is a sale or a rent.")
  end

  it "attaches a repeat enquiry to the open lead and leaves the budget alone" do
    existing = create(:lead, firm:, mobile: "+919876543210", transaction_type: "sale",
      property_type: under_construction, budget_max: 9_000_000, lead_status: new_status)

    post_inbound("99acres", "projects", buyer(listing: project.name))

    expect(response.parsed_body["status"]).to eq("already_in_pipeline")
    expect(leads.where(transaction_type: "sale").count).to eq(1)
    existing.reload
    expect(existing.budget_max).to eq(9_000_000)
    expect(existing.property_type).to eq(under_construction)
    expect(existing.lead_projects.map(&:project_id)).to eq([ project.id ])
    expect(existing.lead_followups.last.comment).to eq("New 99acres enquiry for Lodha Palava.")
  end

  it "treats the same enquiry id as a no-op and still accepts it after a failure" do
    post_inbound("99acres", "projects", buyer(listing: "missing", enquiry_id: "enq-1"))
    expect(response).to have_http_status(:unprocessable_content)
    expect(InboundEnquiry.across_firms.count).to eq(0)

    post_inbound("99acres", "projects", buyer(listing: project.code, enquiry_id: "enq-1"))
    expect(response.parsed_body["status"]).to eq("created")

    expect {
      post_inbound("99acres", "projects", buyer(listing: project.code, enquiry_id: "enq-1"))
    }.not_to change { leads.count + LeadFollowup.across_firms.count }
    expect(response.parsed_body["status"]).to eq("already_in_pipeline")
  end

  it "opens a new lead when the earlier one for that mobile is dead" do
    dead = create(:lead_status, :dead)
    create(:lead, firm:, mobile: "+919876543210", transaction_type: "sale",
      property_type: under_construction, lead_status: dead, dead_reason: "Not buying",
      budget_max: 9_000_000)

    post_inbound("99acres", "projects", buyer(listing: project.code))

    expect(response.parsed_body["status"]).to eq("created")
    expect(leads.where(transaction_type: "sale").count).to eq(2)
  end

  it "stops working after the key is rotated" do
    old = token
    credential.rotate!(actor: owner)

    post_inbound("99acres", "projects", buyer(listing: project.code), key: old)
    expect(response).to have_http_status(:unauthorized)

    post_inbound("99acres", "projects", buyer(listing: project.code), key: credential.token)
    expect(response).to have_http_status(:ok)
  end

  it "loads the owner without a tenant already set" do
    expect(User).to receive(:across_firms).and_call_original.at_least(:once)

    post_inbound("99acres", "projects", buyer(listing: project.code))

    expect(response).to have_http_status(:ok)
  end

  it "follows the path when the query string names another portal or kind" do
    post "/api/v1/inbound/99acres/projects?kind=properties&channel=general",
      params: buyer(listing: project.code),
      headers: { "Authorization" => "Bearer #{token}" },
      as: :json

    expect(response).to have_http_status(:ok)
    lead = leads.find_by(mobile: "+919876543210")
    expect(lead.lead_source).to eq(source_99acres)
    expect(lead.transaction_type).to eq("sale")
    expect(lead.lead_projects.map(&:project_id)).to eq([ project.id ])
  end

  it "keeps a real email and drops one that is not an address" do
    post_inbound("99acres", "projects", buyer(listing: project.code, email: "rahul@example.com"))
    expect(leads.find_by(mobile: "+919876543210").email).to eq("rahul@example.com")

    post_inbound("99acres", "projects", buyer(listing: project.code, mobile: "9876543211", email: "not-an-email"))
    expect(response).to have_http_status(:ok)
    expect(leads.find_by(mobile: "+919876543211").email).to be_nil
  end

  it "refuses a budget that will not fit in rupees" do
    post_inbound("general", "projects", buyer(
      budget: "1" + ("0" * 19), city: "Mumbai", locality: "Kharghar", configuration: "2 BHK"
    ))

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "message")).to eq("Type the budget in rupees, for example 12000000.")
    expect(leads.count).to eq(0)
  end

  it "refuses an enquiry id that will not fit" do
    post_inbound("99acres", "projects", buyer(listing: project.code, enquiry_id: "e" * 256))

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "message")).to eq("That enquiry id is too long.")
    expect(leads.count).to eq(0)
    expect(InboundEnquiry.across_firms.count).to eq(0)
  end

  it "refuses a body that is larger than a small enquiry" do
    expect {
      post_inbound("99acres", "projects", buyer(listing: "x" * 9_000))
    }.not_to change { Notification.across_firms.count }

    expect(response).to have_http_status(:content_too_large)
    expect(response.parsed_body.dig("error", "code")).to eq("invalid")
    expect(leads.count).to eq(0)
  end

  it "treats an enquiry-id collision as already saved" do
    allow(InboundEnquiry).to receive(:create!).and_raise(
      ActiveRecord::RecordNotUnique,
      'duplicate key value violates unique constraint "index_inbound_enquiries_on_firm_channel_and_external_id"'
    )

    post_inbound("99acres", "projects", buyer(listing: project.code, enquiry_id: "enq-race"))

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["status"]).to eq("already_in_pipeline")
    expect(leads.count).to eq(0)
  end

  it "does not claim success when a different unique index collides" do
    allow(InboundEnquiry).to receive(:create!).and_raise(
      ActiveRecord::RecordNotUnique,
      'duplicate key value violates unique constraint "index_leads_on_firm_id_and_code"'
    )

    post_inbound("99acres", "projects", buyer(listing: project.code, enquiry_id: "enq-code"))

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "message")).to eq("We could not save this enquiry.")
    expect(leads.count).to eq(0)
  end

  context "when the limit store is counting" do
    let(:store) { ActiveSupport::Cache::MemoryStore.new }

    before { allow(Inbound::Throttle).to receive(:cache).and_return(store) }

    it "stops inventing keys from one address" do
      Inbound::Throttle::FAILED_AUTHS.times do |n|
        post_inbound("99acres", "projects", buyer(listing: project.code), key: "nope-#{n}")
        expect(response).to have_http_status(:unauthorized)
      end

      expect {
        post_inbound("99acres", "projects", buyer(listing: project.code), key: "nope-again")
      }.not_to change { Notification.across_firms.count }

      expect(response).to have_http_status(:too_many_requests)
      expect(response.parsed_body.dig("error", "code")).to eq("rate_limited")
    end

    it "stops a valid key after its minute is used" do
      Inbound::Throttle::PER_KEY.times do |n|
        post_inbound(
          "99acres", "projects",
          buyer(listing: "missing-#{n}", mobile: format("%010d", 9_000_000_000 + n))
        )
        expect(response).to have_http_status(:unprocessable_content)
      end

      post_inbound("99acres", "projects", buyer(listing: project.code, mobile: "9876543299"))

      expect(response).to have_http_status(:too_many_requests)
      expect(leads.count).to eq(0)
    end

    it "tells the owner about at most ten rejected buyers a day" do
      11.times do |n|
        post_inbound("housing", "properties", buyer(mobile: format("%010d", 8_000_000_000 + n)))
        expect(response).to have_http_status(:unprocessable_content)
      end

      expect(Notification.across_firms.where(user: owner, kind: "inbound_enquiry").count)
        .to eq(Inbound::Throttle::FAILURE_NOTICES)
    end
  end
end
