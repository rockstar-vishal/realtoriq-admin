# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin registration queue" do
  let(:city) { create(:city, name: "Pune") }
  let(:locality) { create(:locality, city:, name: "Kothrud") }

  def submitted_application
    verify_registration_contact("mobile", "9876543210")
    verify_registration_contact("email", "asha@example.com")
    post "/self-signup", params: registration_fields(city:, locality:)
    OnboardingApplication.across_firms.order(:created_at).last
  end

  it "lists an awaiting application, refuses activation without a live plan, then activates" do
    application = submitted_application
    sign_in_admin

    get admin_applications_path
    expect(response.body).to include(application.reference)
    expect(response.body).to include("Lapses in")

    patch activate_admin_firm_path(application.firm)
    expect(flash[:alert]).to eq(Onboarding::PLAN_REQUIRED)
    expect(application.firm.reload).to be_pending

    subscription = create(:subscription, :expired, firm: application.firm)
    patch activate_admin_firm_path(application.firm)
    expect(flash[:alert]).to eq(Onboarding::PLAN_REQUIRED)

    subscription.update!(current_period_start: Date.current, current_period_end: Date.current + 1.month)
    patch activate_admin_firm_path(application.firm)
    expect(application.firm.reload).to be_active
    perform_enqueued_jobs
    expect(ActionMailer::Base.deliveries.map(&:subject)).to include("Your RealtorIQ workspace is ready")

    get admin_applications_path(tab: "activated")
    expect(response.body).to include(application.reference)
  end

  it "activates an ops-created pending firm without a registration plan check" do
    firm = create(:firm, :pending)
    sign_in_admin

    patch activate_admin_firm_path(firm)

    expect(firm.reload).to be_active
  end

  it "rejects with a reason and emails it" do
    application = submitted_application
    sign_in_admin

    post reject_admin_application_path(application), params: { reason: "RERA certificate is unreadable" }

    expect(application.reload).to be_rejected
    expect(application.firm.reload).to be_discarded
    expect(User.across_firms.find_by(mobile: application.mobile)).to be_nil
    perform_enqueued_jobs
    mail = ActionMailer::Base.deliveries.find { |item| item.subject.include?("not accepted") }
    expect(mail.subject).to include("not accepted")
    expect(mail.body.encoded).to include("RERA certificate is unreadable")
    expect(mail.body.encoded).to include(Onboarding::REGISTER_URL)
  end

  it "streams a document inline and does not publish a blob URL" do
    application = submitted_application
    sign_in_admin

    get file_admin_application_path(application, slot: "visiting_card")

    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.body.b).to start_with("\x89PNG".b)
    expect(response.body).not_to include("active_storage")
  end

  it "edits the application and the firm, and audits field names only" do
    application = submitted_application
    sign_in_admin
    slug = application.firm.slug

    patch admin_application_path(application), params: {
      onboarding_application: { firm_name: "Kulkarni Homes" }
    }

    expect(application.reload.firm_name).to eq("Kulkarni Homes")
    expect(application.firm.reload.name).to eq("Kulkarni Homes")
    expect(application.firm.slug).to eq(slug)
    event = AuditEvent.find_by!(action: "onboarding.edited", subject: application)
    expect(event.metadata["fields"]).to eq([ "firm_name" ])
    expect(event.metadata.to_s).not_to include("Kulkarni Homes")
  end

  it "requires an admin for the queue and for a document" do
    application = submitted_application

    get admin_applications_path
    expect(response).to redirect_to(new_admin_session_path)

    get file_admin_application_path(application, slot: "visiting_card")
    expect(response).to redirect_to(new_admin_session_path)
  end

  it "searches by reference and shows a same-name firm as a duplicate" do
    application = submitted_application
    other = create(:firm, name: "Kulkarni Estates")
    sign_in_admin

    get admin_applications_path(q: application.reference)
    expect(response.body).to include(application.reference)

    get admin_applications_path(q: "RIQ-NOTREAL")
    expect(response.body).not_to include(application.reference)

    get admin_application_path(application)
    expect(response.body).to include("Possible duplicates")
    expect(response.body).to include(admin_firm_path(other))
  end

  it "does not change the verified mobile from the edit form" do
    application = submitted_application
    sign_in_admin
    mobile = application.mobile

    patch admin_application_path(application), params: {
      onboarding_application: { mobile: "9999999999", firm_name: "Kulkarni Homes" }
    }

    expect(application.reload.mobile).to eq(mobile)
    expect(application.firm_name).to eq("Kulkarni Homes")
  end

  it "shows a discarded firm with no actions" do
    application = submitted_application
    sign_in_admin
    Onboarding::Reject.call(application:, admin: AdminUser.last, reason: "No")

    get admin_firm_path(application.firm)

    expect(response.body).to include("Discarded")
    expect(response.body).not_to include('value="Activate"')
    expect(response.body).not_to include(">Activate<")
  end
end
