# frozen_string_literal: true

require "rails_helper"

RSpec.describe Facebook::ProcessLeadJob do
  let!(:lead_status) { create(:lead_status, :new_lead) }
  let!(:dead_status) { create(:lead_status, :dead) }
  let!(:under_construction) { create(:property_type, name: "Under construction") }
  let!(:ready_possession) { create(:property_type, name: "Ready possession") }
  let!(:source) { create(:lead_source, name: "Social / Meta", category: "social") }
  let(:firm) { create(:firm) }
  let(:connection) { create(:facebook_connection, firm:) }
  let(:page) do
    create(:facebook_page, firm:, facebook_connection: connection, subscribed: true, status: "active")
  end
  let(:locality) { create(:locality) }
  let(:project) { create(:project, firm:, locality:, city: locality.city) }
  let!(:project_typology) { create(:project_typology, project:) }
  let(:form) { create(:facebook_lead_form, firm:, facebook_page: page, project:) }
  let(:client) { instance_double(Facebook::GraphApiClient) }

  before do
    Current.firm = firm
    allow(Facebook::GraphApiClient).to receive(:new).and_return(client)
  end

  after { Current.reset }

  def lead_payload(mobile: "+919800011122", form_id: form.form_id, extra: {})
    {
      "form_id" => form_id,
      "ad_name" => "Harbour ad",
      "field_data" => [
        { "name" => "full_name", "values" => [ "Rhea Kapoor" ] },
        { "name" => "phone_number", "values" => [ mobile ] },
        { "name" => "email", "values" => [ "rhea@example.com" ] }
      ]
    }.merge(extra)
  end

  def run(import)
    described_class.perform_now(firm.id, import.id)
    import.reload
  end

  it "creates a sale lead from the project, including a non-Indian mobile" do
    import = create(:facebook_lead_import, firm:, facebook_page: page, facebook_lead_form: form, leadgen_id: "lg-us")
    allow(client).to receive(:fetch_lead).and_return(lead_payload(mobile: "+1 415 555 2671"))

    run(import)

    lead = import.lead
    expect(import).to be_created
    expect(lead.mobile).to eq("+14155552671")
    expect(lead.name).to eq("Rhea Kapoor")
    expect(lead.transaction_type).to eq("sale")
    expect(lead.property_type).to eq(under_construction)
    expect(lead.budget_max).to eq(project.starting_budget)
    expect(lead.typology_ids).to eq([ project_typology.typology_id ])
    expect(lead.locality_ids).to eq([ locality.id ])
    expect(lead.lead_source).to eq(source)
    expect(lead.source_detail).to eq("Facebook · #{form.form_name} · Harbour ad")
    expect(lead.notes).to include("Client's requirements")
    expect(lead.lead_projects.map(&:project_id)).to eq([ project.id ])
    notice = Notification.across_firms.find_by!(dedupe_key: "fb_lead:lg-us")
    expect(notice.title).to eq("New Facebook lead")
    expect(notice.data).to include("page" => "leads", "item" => lead.id)
    expect(notice.user_id).to eq(connection.connected_by_user_id)
  end

  it "keeps a mapped note and does not add the project requirements blurb" do
    form.update!(field_mappings: { "full_name" => "name", "phone_number" => "mobile", "view" => "notes" },
      questions: [ { "key" => "view", "label" => "View" } ])
    import = create(:facebook_lead_import, firm:, facebook_page: page, facebook_lead_form: form)
    allow(client).to receive(:fetch_lead).and_return(lead_payload(extra: {
      "field_data" => [
        { "name" => "full_name", "values" => [ "Rhea Kapoor" ] },
        { "name" => "phone_number", "values" => [ "+919800011122" ] },
        { "name" => "view", "values" => [ "Sea view" ] }
      ]
    }))

    run(import)

    expect(import.lead.notes).to eq("View: Sea view")
  end

  it "creates a lead for a marketplace project" do
    catalog = Current.set(firm: nil) do
      create(:project, :catalog, firm: nil, name: "Harbour One", locality:, city: locality.city,
        external_ref: "launchiq-fb")
    end
    create(:project_typology, project: catalog)
    form.update!(project: catalog)
    import = create(:facebook_lead_import, firm:, facebook_page: page, facebook_lead_form: form)
    allow(client).to receive(:fetch_lead).and_return(lead_payload)

    run(import)

    expect(import).to be_created
    expect(import.lead.lead_projects.map(&:project_id)).to eq([ catalog.id ])
  end

  it "links a sale property and a rent property with the listing's price" do
    sale = create(:property, firm:, listing_for: "sale")
    form.update!(project: nil, property: sale)
    import = create(:facebook_lead_import, firm:, facebook_page: page, facebook_lead_form: form, leadgen_id: "lg-sale")
    allow(client).to receive(:fetch_lead).and_return(lead_payload(mobile: "+919800011133"))
    run(import)
    expect(import.lead.transaction_type).to eq("sale")
    expect(import.lead.property_type).to eq(ready_possession)
    expect(import.lead.budget_max).to eq(sale.price)
    expect(import.lead.lead_properties.map(&:property_id)).to eq([ sale.id ])

    rent = create(:property, firm:, listing_for: "rent", price: 45_000)
    form.update!(property: rent)
    rent_import = create(:facebook_lead_import, firm:, facebook_page: page, facebook_lead_form: form, leadgen_id: "lg-rent")
    allow(client).to receive(:fetch_lead).and_return(lead_payload(mobile: "+919800011144"))
    run(rent_import)
    expect(rent_import.lead.transaction_type).to eq("rent")
    expect(rent_import.lead.property_type).to be_nil
    expect(rent_import.lead.budget_max).to eq(45_000)
  end

  it "records a duplicate without merging and notifies once inside six hours" do
    existing = create(:lead, firm:, mobile: "+919800011122", lead_status:, transaction_type: "sale")
    first = create(:facebook_lead_import, firm:, facebook_page: page, facebook_lead_form: form, leadgen_id: "lg-dup-1")
    second = create(:facebook_lead_import, firm:, facebook_page: page, facebook_lead_form: form, leadgen_id: "lg-dup-2")
    allow(client).to receive(:fetch_lead).and_return(lead_payload)

    run(first)
    run(second)

    expect(first).to be_duplicate
    expect(first.lead).to eq(existing)
    expect(existing.lead_projects).to be_empty
    expect(second).to be_duplicate
    expect(Notification.across_firms.where("dedupe_key LIKE ?", "fb_duplicate:%").count).to eq(1)
    notice = Notification.across_firms.find_by!("dedupe_key LIKE ?", "fb_duplicate:%")
    expect(notice.body).to include(existing.code)
    expect(notice.data).to include("page" => "settings", "item" => "facebook")
  end

  it "creates a new lead when the earlier one is dead" do
    create(:lead, firm:, mobile: "+919800011122", lead_status: dead_status, dead_reason: "Not interested",
      transaction_type: "sale")
    import = create(:facebook_lead_import, firm:, facebook_page: page, facebook_lead_form: form)
    allow(client).to receive(:fetch_lead).and_return(lead_payload)

    expect { run(import) }.to change { Lead.unscoped.where(firm_id: firm.id).count }.by(1)
  end

  it "dies on a malformed mobile and on an archived project" do
    import = create(:facebook_lead_import, firm:, facebook_page: page, facebook_lead_form: form, leadgen_id: "lg-bad")
    allow(client).to receive(:fetch_lead).and_return(lead_payload(mobile: "abc"))
    run(import)
    expect(import).to be_dead
    expect(import.error_message).to eq("Mobile is missing or isn't a valid phone number")
    expect(import.failure_alert_pending_at).to be_present

    project.update!(status: "archived")
    archived = create(:facebook_lead_import, firm:, facebook_page: page, facebook_lead_form: form, leadgen_id: "lg-arch")
    allow(client).to receive(:fetch_lead).and_return(lead_payload)
    run(archived)
    expect(archived.error_message).to include("no longer active")
    expect(archived.failure_alert_pending_at).to be_present
  end

  it "skips a turned-off form without a digest, then imports after the form is ready" do
    form.update!(active: false)
    skipped = create(:facebook_lead_import, firm:, facebook_page: page, facebook_lead_form: form, leadgen_id: "lg-off")
    allow(client).to receive(:fetch_lead).and_return(lead_payload)
    run(skipped)
    expect(skipped).to be_dead
    expect(skipped.error_message).to eq("Form is turned off")
    expect(skipped.failure_alert_pending_at).to be_nil

    bare = create(:facebook_lead_form, firm:, facebook_page: page, project: nil, property: nil, form_name: "Bare")
    waiting = create(:facebook_lead_import, firm:, facebook_page: page, facebook_lead_form: bare, leadgen_id: "lg-wait")
    allow(client).to receive(:fetch_lead).and_return(lead_payload(form_id: bare.form_id, mobile: "+919800011155"))
    run(waiting)
    expect(waiting.error_message).to eq("Pick a project or property for this form")
    expect(waiting.failure_alert_pending_at).to be_present

    bare.update!(project:)
    waiting.queue_retry!
    described_class.perform_now(firm.id, waiting.id)
    expect(waiting.reload).to be_created
  end

  it "says the chosen lead source is turned off" do
    chosen = create(:lead_source, name: "Old ads", active: true)
    form.update!(lead_source: chosen)
    chosen.update!(active: false)
    import = create(:facebook_lead_import, firm:, facebook_page: page, facebook_lead_form: form, leadgen_id: "lg-source")
    allow(client).to receive(:fetch_lead).and_return(lead_payload)

    run(import)

    expect(import).to be_dead
    expect(import.error_message).to eq("The chosen lead source is turned off")
  end

  it "auto-creates a form for an unknown form on this page" do
    import = create(:facebook_lead_import, firm:, facebook_page: page, facebook_lead_form: nil, leadgen_id: "lg-auto")
    allow(client).to receive(:fetch_lead).and_return(lead_payload(form_id: "brand-new"))
    run(import)
    created = FacebookLeadForm.across_firms.find_by!(form_id: "brand-new")
    expect(created.firm_id).to eq(firm.id)
    expect(created.active).to be true
    expect(import.error_message).to eq("Pick a project or property for this form")
  end

  it "stops only the Page when its token is dead" do
    import = create(:facebook_lead_import, firm:, facebook_page: page, facebook_lead_form: form)
    other_page = create(:facebook_page, firm:, facebook_connection: connection, subscribed: true, status: "active")
    allow(client).to receive(:fetch_lead).and_raise(Facebook::Errors::TokenInvalidError.new("no", fb_error_code: "190"))

    run(import)

    expect(import).to be_dead
    expect(import.error_message).to eq("This Facebook Page needs to be connected again")
    expect(import.failure_alert_pending_at).to be_nil
    expect(page.reload).to be_page_error
    expect(other_page.reload).to be_page_active
    expect(connection.reload).to be_connection_active
    expect(Facebook::PageAttentionJob).to have_been_enqueued.with(firm.id, page.id).once
    expect(Facebook::TokenInvalidAlertJob).not_to have_been_enqueued
  end

  it "retries a rate limit and dies on the fifth failure" do
    import = create(:facebook_lead_import, firm:, facebook_page: page, facebook_lead_form: form)
    allow(client).to receive(:fetch_lead).and_raise(Facebook::Errors::RateLimitError.new("slow"))

    run(import)
    expect(import).to be_failed
    expect(import.retry_count).to eq(1)
    expect(import.next_attempt_at).to be_within(5.seconds).of(1.minute.from_now)
    expect(described_class).to have_been_enqueued.with(firm.id, import.id)

    import.update!(retry_count: 4, status: "failed", next_attempt_at: Time.current)
    run(import)
    expect(import).to be_dead
    expect(import.failure_alert_pending_at).to be_present
  end

  it "leaves a deactivated assignee unassigned" do
    agent = create(:user, firm:, status: "disabled")
    form.update!(assigned_user: agent)
    import = create(:facebook_lead_import, firm:, facebook_page: page, facebook_lead_form: form)
    allow(client).to receive(:fetch_lead).and_return(lead_payload(mobile: "+919800011166"))

    run(import)

    expect(import).to be_created
    expect(import.lead.assigned_user_id).to be_nil
    expect(import.error_details["assignee_dropped"]).to be true
  end

  it "rolls the lead back when saving the import fails" do
    import = create(:facebook_lead_import, firm:, facebook_page: page, facebook_lead_form: form)
    allow(client).to receive(:fetch_lead).and_return(lead_payload(mobile: "+919800011177"))
    allow_any_instance_of(FacebookLeadImport).to receive(:mark_created!).and_raise(RuntimeError, "boom")

    expect { run(import) }.not_to change { Lead.unscoped.count }
    expect(import).not_to be_created
    expect(import).to be_failed
  end

  it "dies when the page token cannot be read" do
    import = create(:facebook_lead_import, firm:, facebook_page: page, facebook_lead_form: form)
    allow_any_instance_of(FacebookPage).to receive(:page_access_token)
      .and_raise(ActiveRecord::Encryption::Errors::Decryption)

    run(import)

    expect(import).to be_dead
    expect(import.error_message).to eq("Could not read the Page token")
  end
end
