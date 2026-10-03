# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Turbo marketplace events" do
  let(:secret) { "test-webhook-secret" }
  let!(:city) { create(:city, name: "Mumbai", state: "Maharashtra") }
  let!(:new_status) { create(:lead_status, :new_lead) }
  let!(:dead_status) { create(:lead_status, :dead) }
  let!(:property_type) { create(:property_type, name: "Under construction") }

  before do
    allow(Realtoriq::Credentials).to receive(:webhook_secret).and_return(secret)
  end

  def post_event(payload = nil, signature: nil, **extra)
    payload = extra if payload.nil?
    body = JSON.generate(payload)
    signature ||= "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, body)}"
    post "/turbo/events",
      params: body,
      headers: {
        "CONTENT_TYPE" => "application/json",
        "ACCEPT" => "application/json",
        "X-RealtorIQ-Signature" => signature
      }
  end

  def upsert_payload(overrides = {})
    {
      event: "upsert",
      pushed_at: "2026-09-28T12:00:00Z",
      project_code: "PR4F2A9C",
      project_name: "Harbour One",
      developer_name: "Lodha",
      company_code: "CL00A1B2C3",
      rera_number: "P51800000001",
      possession_on: "2027-12-31",
      city: "Mumbai",
      locality: "Worli",
      address: "12 Sea Face",
      rm_name: "Asha Rao",
      rm_contact: "9876543210",
      unit_types: [
        { label: "2 BHK", typology_name: "2BHK", area_min: 650, area_unit: "sqft", price_min: 15_000_000, price_max: 18_000_000 }
      ]
    }.merge(overrides)
  end

  it "rejects a bad signature with a string error" do
    post_event(upsert_payload, signature: "sha256=nope")

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body["error"]).to eq("Unauthorized")
  end

  it "creates one catalog project and hides it without deleting" do
    expect { post_event(upsert_payload) }.to have_enqueued_job(Realtoriq::SyncProjectAssetsJob)

    expect(response).to have_http_status(:accepted)
    project = Project.unscoped.find_by(external_ref: "PR4F2A9C")
    expect(project.firm_id).to be_nil
    expect(project).to be_from_catalog
    expect(project.starting_budget).to eq(15_000_000)
    expect(project.rm_name).to eq("Asha Rao")
    expect(project.builder.name).to eq("Lodha")
    expect(project.rera_number).to eq("P51800000001")
    expect(project.possession_on).to eq(Date.new(2027, 12, 31))
    expect(project.possession_label).to be_nil
    expect(project.locality.name).to eq("Worli")
    expect(project.project_typologies.map { |row| row.typology.name }).to eq([ "2BHK" ])
    expect(Builder.where(firm_id: nil).pluck(:name)).not_to include("CL00A1B2C3")

    Current.firm = nil
    expect(Project.count).to eq(0)

    post_event(upsert_payload(pushed_at: "2026-09-28T11:00:00Z", project_name: "Stale"))
    expect(project.reload.name).to eq("Harbour One")

    post_event(event: "hide", pushed_at: "2026-09-28T13:00:00Z", project_code: "PR4F2A9C", share: false)
    expect(project.reload).to be_archived
    expect(Project.unscoped.where(external_ref: "PR4F2A9C").count).to eq(1)
  end

  it "refuses an unknown city with a string error" do
    post_event(upsert_payload(city: "Nowhere"))

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to eq("City Nowhere is not in RealtorIQ")
  end

  describe "enquiries" do
    let(:plan) { create(:plan) }
    let(:firm) { create(:firm, status: :active) }
    let!(:subscription) { create(:subscription, firm:, plan:) }
    let!(:broker) { create(:user, :agent, firm:, email: "broker@example.com") }
    let!(:project) do
      post_event(upsert_payload)
      Project.unscoped.find_by!(external_ref: "PR4F2A9C")
    end
    let!(:link) do
      Current.firm = firm
      ProjectShareLink.create!(firm:, user: broker, project:)
    end
    let!(:microsite_source) { create(:lead_source, name: "Builder Microsite", category: "other") }

    def enquire(phone: "9876543210", enquiry_id: SecureRandom.uuid, pushed_at: Time.current.utc.iso8601)
      post_event(
        event: "enquiry",
        pushed_at:,
        submitted_at: Time.current.utc.iso8601,
        enquiry_id:,
        project_code: "PR4F2A9C",
        company_code: "CL00A1B2C3",
        share_token: link.token,
        name: "Meera Shah",
        phone:,
        message: "Saturday morning"
      )
    end

    it "creates a sale lead for the broker and links the marketplace project" do
      enquire

      expect(response).to have_http_status(:ok)
      Current.firm = firm
      lead = Lead.find_by(mobile: "+919876543210")
      expect(lead.name).to eq("Meera Shah")
      expect(lead.assigned_user).to eq(broker)
      expect(lead.property_type).to eq(property_type)
      expect(lead.lead_projects.map(&:project_id)).to eq([ project.id ])
      expect(Project.unscoped.where(firm_id: firm.id, source: "own")).to be_empty
      expect(lead.notes).to eq("Saturday morning")
      expect(lead.lead_source).to eq(microsite_source)
    end

    it "does not duplicate a live lead and emails the owner" do
      create(:lead, firm:, mobile: "9876543210", lead_status: new_status,
        property_type:, assigned_user: broker, transaction_type: "sale")

      perform_enqueued_jobs { enquire }

      expect(response).to have_http_status(:ok)
      expect(Lead.unscoped.where(firm:, mobile: "+919876543210").count).to eq(1)
      Current.firm = firm
      expect(Lead.find_by(mobile: "+919876543210").lead_followups).to be_present
      mail = ActionMailer::Base.deliveries.last
      expect(mail.to).to eq([ "broker@example.com" ])
      expect(mail[:from].formatted).to eq([ "RealtorIQ by KGen <realtoriq-noreply@kgen.tech>" ])
      Current.firm = firm
      notice = broker.notifications.find_by(kind: "marketplace_enquiry")
      expect(notice.title).to eq("Marketplace enquiry on #{Lead.find_by(mobile: '+919876543210').code}")
    end

    it "does not copy the project when a second enquiry arrives" do
      enquire
      enquire(phone: "9876543211")

      expect(response).to have_http_status(:ok)
      expect(Project.unscoped.where(firm_id: firm.id, source: "own", external_ref: "PR4F2A9C")).to be_empty
      Current.firm = firm
      expect(Lead.find_by(mobile: "+919876543211").lead_projects.map(&:project_id)).to eq([ project.id ])
    end

    it "creates a fresh lead when the earlier one is dead" do
      lead = create(:lead, firm:, mobile: "9876543210", lead_status: new_status,
        property_type:, assigned_user: broker, transaction_type: "sale")
      Leads::TransitionStatus.new(lead:, to_status: dead_status, actor: broker, reason: "Not buying").call

      enquire

      expect(response).to have_http_status(:ok)
      expect(Lead.unscoped.where(firm:, mobile: "+919876543210").count).to eq(2)
    end

    it "shows the buyer a string error for a bad token" do
      post_event(
        event: "enquiry", pushed_at: Time.current.utc.iso8601, enquiry_id: SecureRandom.uuid,
        project_code: "PR4F2A9C",
        share_token: "missing", name: "Meera Shah", phone: "9876543210"
      )

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to eq("This link is not valid.")
    end

    it "treats the same enquiry id as a no-op" do
      create(:lead, firm:, mobile: "9876543210", lead_status: new_status,
        property_type:, assigned_user: broker, transaction_type: "sale")
      enquiry_id = SecureRandom.uuid

      perform_enqueued_jobs { enquire(enquiry_id:) }
      perform_enqueued_jobs { enquire(enquiry_id:) }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("ok" => true)
      Current.firm = firm
      lead = Lead.find_by(mobile: "+919876543210")
      expect(lead.lead_followups.count).to eq(1)
      expect(ActionMailer::Base.deliveries.size).to eq(1)
      expect(broker.notifications.where(kind: "marketplace_enquiry").count).to eq(1)
      expect(MarketplaceEnquiry.across_firms.where(enquiry_id:).count).to eq(1)
    end

    it "returns 200 when the enquiry id is rejected by validation" do
      enquiry_id = "enq-repeat"
      enquire(enquiry_id:)
      allow(MarketplaceEnquiry).to receive(:across_firms).and_wrap_original do |original|
        scope = original.call
        allow(scope).to receive(:exists?).and_return(false)
        scope
      end

      enquire(enquiry_id:)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("ok" => true)
      expect(MarketplaceEnquiry.across_firms.where(enquiry_id:).count).to eq(1)
    end

    it "returns 200 when a live lead is inserted while the enquiry is saved" do
      create(:lead, firm:, mobile: "9876543210", lead_status: new_status,
        property_type:, assigned_user: broker, transaction_type: "sale")
      allow(Lead).to receive(:unscoped).and_wrap_original do |original, *args, &block|
        result = original.call(*args, &block)
        if block.nil? && result.is_a?(ActiveRecord::Relation)
          allow(result).to receive(:find_by).and_wrap_original do |find, *find_args|
            attrs = find_args.first
            attrs.is_a?(Hash) && attrs.key?(:open_identity) ? nil : find.call(*find_args)
          end
        end
        result
      end
      checks = 0
      allow_any_instance_of(Lead).to receive(:duplicate_on_mobile_and_type).and_wrap_original do |method|
        checks += 1
        checks <= 2 ? nil : method.call
      end

      enquire

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("ok" => true)
      expect(Lead.unscoped.where(firm:, mobile: "+919876543210").count).to eq(1)
    end

    it "refuses an enquiry whose pushed_at is older than ten minutes" do
      enquire(pushed_at: 11.minutes.ago.utc.iso8601)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to eq("This enquiry has expired.")
      expect(Lead.unscoped.where(firm:).count).to eq(0)
    end

    it "gives a deactivated sharer's enquiry to the super admin" do
      admin = create(:user, :super_admin, firm:, email: "admin@example.com")
      broker.update!(status: :disabled)

      enquire

      expect(response).to have_http_status(:ok)
      Current.firm = firm
      lead = Lead.find_by(mobile: "+919876543210")
      expect(lead.assigned_user).to eq(admin)
    end

    it "still accepts an enquiry when the subscription has lapsed" do
      subscription.update!(status: :lapsed)

      enquire

      expect(response).to have_http_status(:ok)
      expect(Lead.unscoped.where(firm:, mobile: "+919876543210").count).to eq(1)
    end
  end

  def allow_launch_host
    allow(Realtoriq::Credentials).to receive(:turbo_public_origin).and_return("https://launch.example")
    allow(Realtoriq::Credentials).to receive(:turbo_api_origin).and_return("https://launch.example")
  end

  it "stores promo text, starting brokerage, the LaunchIQ brochure link, and queues the brokerage ladder" do
    allow_launch_host
    payload = upsert_payload(
      promo_text: "Launch offer",
      brokerage_percent: "2.5",
      brochure: { url: "https://launch.example/brochure.pdf", checksum: "abc", filename: "brochure.pdf" },
      brokerage_ladder: { url: "https://launch.example/ladder.jpg", checksum: "abc", filename: "ladder.jpg" }
    )

    expect { post_event(payload) }.to have_enqueued_job(Realtoriq::SyncProjectAssetsJob)

    project = Project.unscoped.find_by!(external_ref: "PR4F2A9C")
    expect(project.promo_text).to eq("Launch offer")
    expect(project.promo_ends_on).to be_nil
    expect(project).to be_promo_live
    expect(project.brokerage_percent).to eq(BigDecimal("2.5"))
    expect(project.brochure_source_url).to eq("https://launch.example/brochure.pdf")
    job = ActiveJob::Base.queue_adapter.enqueued_jobs.find { |entry| entry[:job] == Realtoriq::SyncProjectAssetsJob }
    expect(job[:args][2]).to be_nil
    expect(job[:args].last).to include("url" => "https://launch.example/ladder.jpg")
  end

  it "stores a brochure sent on the API host under the public origin" do
    allow(Realtoriq::Credentials).to receive(:turbo_public_origin).and_return("https://r.example")
    allow(Realtoriq::Credentials).to receive(:turbo_api_origin).and_return("https://fb-connect.example")
    brochure = "https://fb-connect.example/rails/active_storage/blobs/redirect/abc/brochure-grove.pdf"

    post_event(upsert_payload(
      brochure: { url: brochure, checksum: "abc", filename: "brochure-grove.pdf" }
    ))

    project = Project.unscoped.find_by!(external_ref: "PR4F2A9C")
    expect(project.brochure_source_url).to eq(
      "https://r.example/rails/active_storage/blobs/redirect/abc/brochure-grove.pdf"
    )
  end

  it "leaves the stored brochure alone when the new URL is not on LaunchIQ" do
    allow_launch_host
    post_event(upsert_payload(
      brochure: { url: "https://launch.example/brochure.pdf", checksum: "abc", filename: "brochure.pdf" }
    ))
    project = Project.unscoped.find_by!(external_ref: "PR4F2A9C")
    Current.set(firm_scope_bypassed: true) do
      project.brochure.attach(io: StringIO.new("%PDF"), filename: "old.pdf", content_type: "application/pdf")
    end

    expect {
      post_event(upsert_payload(
        pushed_at: "2026-09-28T12:05:00Z",
        brochure: { url: "https://evil.example/phish.pdf", checksum: "abc", filename: "phish.pdf" }
      ))
    }.not_to have_enqueued_job(ActiveStorage::PurgeJob)

    expect(project.reload.brochure_source_url).to eq("https://launch.example/brochure.pdf")
    Current.set(firm_scope_bypassed: true) do
      expect(project.brochure).to be_attached
    end
  end

  it "clears the brochure link when LaunchIQ sends a blank brochure" do
    allow_launch_host
    post_event(upsert_payload(
      brochure: { url: "https://launch.example/brochure.pdf", checksum: "abc", filename: "brochure.pdf" }
    ))
    project = Project.unscoped.find_by!(external_ref: "PR4F2A9C")
    Current.set(firm_scope_bypassed: true) do
      project.brochure.attach(io: StringIO.new("%PDF"), filename: "old.pdf", content_type: "application/pdf")
    end

    expect {
      post_event(upsert_payload(pushed_at: "2026-09-28T12:05:00Z", brochure: nil))
    }.to have_enqueued_job(ActiveStorage::PurgeJob)

    expect(project.reload.brochure_source_url).to be_nil
  end

  it "refuses an upsert without a developer name, RERA number, or possession date" do
    post_event(upsert_payload(developer_name: " "))

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]).to eq("developer_name is required")

    post_event(upsert_payload(rera_number: " "))
    expect(response.parsed_body["error"]).to eq("rera_number is required")

    post_event(upsert_payload(possession_on: " "))
    expect(response.parsed_body["error"]).to eq("possession_on is required")
  end

  it "matches 2BHK to the existing 2 BHK typology" do
    typology = create(:typology, name: "2 BHK", bedrooms: 2)
    post_event(upsert_payload)

    project = Project.unscoped.find_by!(external_ref: "PR4F2A9C")
    expect(project.typologies).to eq([ typology ])
    expect(Typology.where(name: "2BHK")).to be_empty

    Current.firm = create(:firm, status: :active)
    lead = create(:lead, firm: Current.firm, lead_status: new_status, budget_max: 16_000_000, transaction_type: "sale")
    lead.typologies << typology
    lead.localities << project.locality
    expect(Inventory::MatchInventory.new(lead:).call.map { |row| row[:id] }).to include(project.id)
  end

  it "does not rename a booking copy when the marketplace project is renamed" do
    post_event(upsert_payload)
    catalog = Project.unscoped.find_by!(external_ref: "PR4F2A9C")
    Current.firm = create(:firm, status: :active)
    copy = Inventory::CopyCatalogProject.new(catalog:).call.project

    post_event(upsert_payload(project_name: "Harbour One Phase 2", pushed_at: "2026-09-28T18:00:00Z"))

    expect(copy.reload.name).to eq("Harbour One")
    expect(catalog.reload.name).to eq("Harbour One Phase 2")
  end

  it "archives the catalog row, the firm copies, and the lead mappings on withdraw" do
    post_event(upsert_payload)
    catalog = Project.unscoped.find_by!(external_ref: "PR4F2A9C")
    firm = create(:firm, status: :active)
    Current.firm = firm
    copy = Inventory::CopyCatalogProject.new(catalog:).call.project
    lead = create(:lead, firm:, lead_status: new_status, transaction_type: "sale")
    mapping = create(:lead_project, firm:, lead:, project: copy)

    post_event(event: "withdraw", pushed_at: "2026-09-28T14:00:00Z", project_code: "PR4F2A9C",
      company_code: "CL00A1B2C3", reason: "project_deleted")

    expect(response).to have_http_status(:ok)
    expect(catalog.reload).to be_archived
    expect(copy.reload).to be_archived
    expect(mapping.reload.withdrawn_at).to be_present

    post_event(upsert_payload(pushed_at: "2026-09-28T15:00:00Z"))
    expect(catalog.reload).to be_active
    expect(copy.reload).to be_active
    expect(mapping.reload.withdrawn_at).to be_nil
  end

  it "rejects a JSON array" do
    body = "[1]"
    signature = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, body)}"
    post "/turbo/events", params: body, headers: {
      "CONTENT_TYPE" => "application/json",
      "X-RealtorIQ-Signature" => signature
    }

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body["error"]).to eq("Invalid JSON")
  end
end
