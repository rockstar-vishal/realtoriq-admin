# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Firm website" do
  let(:plan) { create(:plan) }
  let(:firm) { create(:firm, :with_super_admin, name: "Aarav Realty", rera_number: nil) }
  let!(:subscription) { create(:subscription, firm:, plan:) }
  let(:city) { create(:city, name: "Pune") }
  let(:locality) { create(:locality, city:, name: "Kothrud") }
  let(:typology) { create(:typology, name: "2 BHK") }
  let!(:project) do
    create(:project, firm:, city:, locality:, name: "Aurum Vista", brokerage_percent: 17.5,
      address: "12 Canal Road", rera_number: "P52100099999")
  end
  let!(:project_typology) { create(:project_typology, project:, typology:) }
  let(:building) { create(:building, firm:, city:, locality:, name: "Lake View", has_pool: true) }
  let!(:sale) { create(:property, firm:, building:, typology:, listing_for: "sale", confidential_note: "VAULT-NOTE-77") }
  let!(:rental) { create(:property, firm:, building:, typology:, listing_for: "rent", price: 45_000) }
  let(:host) { "cp-#{firm.slug}.realtoriq.kgen.tech" }

  before do
    create(:lead_status, :new_lead)
    create(:lead_source, name: "Broker website", category: "other")
    create(:property_type, name: "Under construction")
    create(:property_type, name: "Ready possession")
    firm.update!(
      about: "A family brokerage.",
      address_line1: "12 MG Road",
      city:,
      locality:,
      pincode: "411038",
      lat: 18.5074,
      lng: 73.8077,
      website_phone: "+919820144210"
    )
  end

  def visit_home
    get "/", headers: { "HOST" => host }
  end

  def post_enquiry(extra = {})
    post "/enquiries", params: { "g-recaptcha-response" => "pass" }.merge(extra), headers: { "HOST" => host }
  end

  def public_project_path(record = project)
    Sites::Host.listing_path("projects", record.code, record.name)
  end

  def public_property_path(record)
    Current.firm = record.firm
    Sites::Host.listing_path("properties", record.code, record.title)
  ensure
    Current.firm = nil
  end

  it "does not use the modern-browser filter or a parent cookie domain" do
    expect(Sites::PagesController.ancestors).not_to include(ApplicationController)
    expect(Rails.application.config.session_options[:domain]).to be_nil
  end

  it "lists this firm's own stock and hides money that is not the buyer's" do
    visit_home

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Aarav Realty")
    expect(response.body).to include("Send message")
    expect(response.body).to include("Not Available")
    expect(response.body).to include("A family brokerage.")
    expect(response.body.index('id="about"')).to be < response.body.index('id="projects"')
    expect(response.body).to include("12 MG Road")
    expect(response.body).to include("tel:+919820144210")
    expect(response.body).to include("https://wa.me/919820144210")
    expect(response.body).to include("query=18.5074000,73.8077000")
    expect(response.body).to include("Aurum Vista")
    expect(response.body).to include(sale.title)
    expect(response.body).not_to include("17.5")
    expect(response.body).not_to include("VAULT-NOTE-77")
  end

  it "shows the firm RERA when it is on file and the project RERA only on that project" do
    firm.update!(rera_number: "A52100000001")

    visit_home
    expect(response.body).to include("A52100000001")
    expect(response.body).not_to include("P52100099999")

    get public_project_path, headers: { "HOST" => host }
    expect(response.body).to include("P52100099999")
    expect(response.body).to include("A52100000001")
  end

  it "links the brochure at the public path, not the storage path" do
    project.brochure.attach(
      io: StringIO.new("%PDF-1.4"), filename: "brochure.pdf", content_type: "application/pdf"
    )

    get public_project_path, headers: { "HOST" => host }

    expect(response.body).to include("/realtoriq/brochures/#{project.code}.pdf")
    expect(response.body).not_to include("active_storage")
  end

  it "keeps a short code, a wrong title, and the older slug working" do
    get "/projects/#{project.code.downcase}", headers: { "HOST" => host }
    expect(response).to redirect_to(public_project_path)

    get "#{public_project_path.sub(%r{/[^/]+\z}, '')}/old-title", headers: { "HOST" => host }
    expect(response).to redirect_to(public_project_path)

    get "/projects/#{project.slug}", headers: { "HOST" => host }
    expect(response).to redirect_to(public_project_path)

    get "/properties/#{sale.code.downcase}", headers: { "HOST" => host }
    expect(response).to redirect_to(public_property_path(sale))

    get "/properties/#{sale.slug}", headers: { "HOST" => host }
    expect(response).to redirect_to(public_property_path(sale))
  end

  it "redirects an older slug that looks like a listing code" do
    project.update_column(:slug, "p-square")

    get "/projects/p-square", headers: { "HOST" => host }

    expect(response).to redirect_to(public_project_path)
  end

  it "answers a HEAD check for a page that exists" do
    head "/", headers: { "HOST" => host }
    expect(response).to have_http_status(:ok)

    head public_project_path, headers: { "HOST" => host }
    expect(response).to have_http_status(:ok)

    head "/admin", headers: { "HOST" => host }
    expect(response).to have_http_status(:not_found)
  end

  it "does not serve another firm's listing, a hidden listing, or the CRM" do
    other = create(:firm, :with_super_admin, name: "Other Realty")
    create(:subscription, firm: other, plan:)
    secret = create(:project, firm: other, name: "Secret Towers")
    project.update!(on_website: false)
    rental.update!(status: "booked")

    get "/projects/#{secret.slug}", headers: { "HOST" => host }
    expect(response).to have_http_status(:not_found)
    expect(response.body).to eq("Not found")

    get public_project_path, headers: { "HOST" => host }
    expect(response).to have_http_status(:not_found)

    visit_home
    expect(response.body).not_to include("Secret Towers")
    expect(response.body).not_to include("Aurum Vista")
    expect(response.body).not_to include("/ month")

    get "/api/v1/me", headers: { "HOST" => host }
    expect(response).to have_http_status(:not_found)
    expect(response.body).to eq("Not found")

    get "/admin", headers: { "HOST" => host }
    expect(response).to have_http_status(:not_found)
  end

  it "is the same 404 when the site is disabled, the firm is suspended, or the host is not a firm" do
    firm.update!(website_enabled: false)
    visit_home
    expect(response).to have_http_status(:not_found)
    expect(response.body).to eq("Not found")

    firm.update!(website_enabled: true, status: "suspended", suspended_at: Time.current, suspension_reason: "Paused")
    visit_home
    expect(response.body).to eq("Not found")

    get "/", headers: { "HOST" => "cp-#{firm.slug}.realtoriq.kgen.tech.evil.example" }
    expect(response.body).not_to include("Aarav Realty")

    get "/up"
    expect(response).to have_http_status(:ok)
  end

  it "keeps a cover on the home and does not point photos at the firm host" do
    project.photos.attach(
      io: StringIO.new("png"), filename: "cover.png", content_type: "image/png"
    )
    firm.logo.attach(
      io: StringIO.new("<svg xmlns='http://www.w3.org/2000/svg'></svg>"),
      filename: "logo.svg", content_type: "image/svg+xml"
    )

    visit_home

    expect(response.body).to include("AR")
    expect(response.body).not_to include("image/svg")
    expect(response.body).not_to include("src=\"http://#{host}")
    expect(response.body).not_to include("src=\"https://#{host}")
    expect(response.body).to include(public_project_path)
  end

  it "creates a sale lead from a project and a rent lead from a rental" do
    post_enquiry(
      name: "Rhea Kapoor", mobile: "9820144210", message: "Is this available?",
      listing_kind: "project", listing_code: project.code
    )

    expect(response).to redirect_to("#{public_project_path}?sent=1")
    lead = Lead.unscoped.find_by!(firm_id: firm.id, mobile: "+919820144210")
    expect(lead.transaction_type).to eq("sale")
    expect(lead.property_type.name).to eq("Under construction")
    expect(lead.lead_source.name).to eq("Broker website")
    expect(lead.lead_projects.map(&:project_id)).to eq([ project.id ])

    post_enquiry(
      name: "Rhea Kapoor", mobile: "9820144211", listing_kind: "property", listing_code: rental.code
    )

    rent_lead = Lead.unscoped.find_by!(firm_id: firm.id, mobile: "+919820144211")
    expect(rent_lead.transaction_type).to eq("rent")
    expect(rent_lead.property_type).to be_nil
    expect(rent_lead.lead_properties.map(&:property_id)).to eq([ rental.id ])
  end

  it "thanks the buyer again when the mobile is already a live lead" do
    post_enquiry(
      name: "Rhea Kapoor", mobile: "9820144210", listing_kind: "project", listing_code: project.code
    )
    post_enquiry(
      name: "Rhea Kapoor", mobile: "9820144210", listing_kind: "project", listing_code: project.code
    )

    expect(response).to redirect_to("#{public_project_path}?sent=1")
    expect(Lead.unscoped.where(firm_id: firm.id, mobile: "+919820144210").count).to eq(1)
    expect(response.body).not_to include("already")
  end

  it "emails a home message and does not create a lead" do
    ActionMailer::Base.deliveries.clear
    perform_enqueued_jobs do
      post_enquiry(name: "Rhea Kapoor", mobile: "9820144213", message: "Please call me.")
    end

    expect(response).to redirect_to("/?sent=1")
    expect(Lead.unscoped.where(firm_id: firm.id).count).to eq(0)
    mail = ActionMailer::Base.deliveries.last
    owner = User.unscoped.find_by!(firm_id: firm.id, role: :super_admin)
    expect(mail.to).to eq([ owner.email ])
    expect(mail.subject).to eq("Message from your website")
    expect(mail.body.encoded).to include("Please call me.")
    expect(mail.body.encoded).to include("+919820144213")
  end

  it "prefers the firm's verified email for a home message" do
    create(:contact_channel, :email, :verified, firm:, value: "desk@example.com")
    ActionMailer::Base.deliveries.clear

    perform_enqueued_jobs do
      post_enquiry(name: "Rhea Kapoor", mobile: "9820144214", message: "A viewing on Saturday.")
    end

    expect(ActionMailer::Base.deliveries.last.to).to eq([ "desk@example.com" ])
    expect(Lead.unscoped.where(firm_id: firm.id).count).to eq(0)
  end

  it "refuses a home message when the broker has nowhere to receive it" do
    User.unscoped.where(firm_id: firm.id, role: "super_admin").update_all(email: nil)

    post_enquiry(name: "Rhea Kapoor", mobile: "9820144215", message: "Hello")

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("Could not send that just now.")
    expect(Lead.unscoped.where(firm_id: firm.id).count).to eq(0)
    expect(ActiveJob::Base.queue_adapter.enqueued_jobs.map { |job| job[:job] }).not_to include(Sites::ContactNotifyJob)
  end

  it "does not create a lead for a listing that is not on the site" do
    post_enquiry(
      name: "Rhea Kapoor", mobile: "9820144216", message: "Hello",
      listing_kind: "project", listing_code: "not-a-real-listing"
    )

    expect(response).to have_http_status(:not_found)
    expect(Lead.unscoped.where(firm_id: firm.id).count).to eq(0)
  end

  it "does not save a honeypot, a failed captcha, or an enquiry the cache cannot count" do
    post_enquiry(name: "Bot", mobile: "9820144212", company: "Acme")
    expect(Lead.unscoped.where(firm_id: firm.id).count).to eq(0)
    expect(ActiveJob::Base.queue_adapter.enqueued_jobs.map { |job| job[:job] }).not_to include(Sites::ContactNotifyJob)

    firm_was_counted = false
    allow(Sites::Throttle).to receive(:allow_firm?).and_wrap_original do |method, *args|
      firm_was_counted = true
      method.call(*args)
    end
    post "/enquiries", params: {
      name: "Rhea Kapoor", mobile: "9820144212", "g-recaptcha-response" => "nope"
    }, headers: { "HOST" => host }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("not a robot")
    expect(Lead.unscoped.where(firm_id: firm.id).count).to eq(0)
    expect(firm_was_counted).to be(false)

    post "/enquiries", params: {
      name: "Rhea Kapoor", mobile: "9820144212", message: "Hello", recaptcha_token: "pass"
    }, headers: { "HOST" => host }
    expect(response).to have_http_status(:unprocessable_content)
    expect(Lead.unscoped.where(firm_id: firm.id).count).to eq(0)

    allow(Rails.cache).to receive(:increment).and_raise(ActiveRecord::ConnectionNotEstablished)
    post_enquiry(name: "Rhea Kapoor", mobile: "9820144212", message: "Hello")
    expect(response).to have_http_status(:too_many_requests)
    expect(Lead.unscoped.where(firm_id: firm.id).count).to eq(0)
  end

  it "keeps one inbox row and one email when the enquiry job runs again" do
    ActionMailer::Base.deliveries.clear
    perform_enqueued_jobs do
      post_enquiry(
        name: "Rhea Kapoor", mobile: "9820144210", message: "Is this available?",
        listing_kind: "project", listing_code: project.code
      )
    end

    lead = Lead.unscoped.find_by!(firm_id: firm.id, mobile: "+919820144210")
    owner = User.unscoped.find_by!(firm_id: firm.id, role: :super_admin)
    note = Notification.unscoped.find_by!(user_id: owner.id, kind: "website_enquiry")
    expect(ActionMailer::Base.deliveries.size).to eq(1)

    Sites::EnquiryNotifyJob.perform_now(
      firm.id, lead.id, owner.id, "Rhea Kapoor", project.name, "created", note.dedupe_key
    )

    expect(Notification.unscoped.where(dedupe_key: note.dedupe_key).count).to eq(1)
    expect(ActionMailer::Base.deliveries.size).to eq(1)
  end

  it "does not treat a laptop host as a firm site on staging" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("staging"))

    expect(Sites::Host.slug_from("cp-#{firm.slug}.lvh.me")).to be_nil
    expect(Sites::Host.slug_from("cp-#{firm.slug}.localhost")).to be_nil
    expect(Sites::Host.slug_from("cp-#{firm.slug}.realtoriq.kgen.tech")).to eq(firm.slug)
  end
end
