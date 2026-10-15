# frozen_string_literal: true

require "rails_helper"

RSpec.describe Onboarding::PurgeJob do
  def create_registration(mobile: "+919812345678", email: "broker@example.com")
    city = create(:city)
    locality = create(:locality, city:)
    firm = create(:firm, :pending, city:, locality:)
    Current.firm = firm
    create(:user, :super_admin, firm:, mobile:, email:)
    terms = Legal::Registry.current(:terms)
    privacy = Legal::Registry.current(:privacy)
    application = OnboardingApplication.create!(
      firm:, reference: OnboardingApplication.generate_reference, status: "submitted",
      applicant_name: "Asha Kulkarni", applicant_designation: "Partner",
      mobile:, whatsapp: "+919812345679", email:,
      mobile_verified_at: Time.current, email_verified_at: Time.current,
      entity_type: "partnership", firm_name: firm.name, legal_name: firm.legal_name,
      rera_registered: false, rera_declared_at: Time.current,
      address_line1: "12 MG Road", city:, locality:, pincode: "411001",
      submitted_at: Time.current, captcha_verified_at: Time.current
    )
    LegalAcceptance.create!(
      firm:, onboarding_application: application,
      terms_version: terms.version, terms_sha256: terms.sha256,
      privacy_version: privacy.version, privacy_sha256: privacy.sha256,
      statement: Onboarding::ACCEPTANCE_STATEMENT, accepted_at: Time.current,
      evidence: { "whatsapp_verified_at" => nil }
    )
    Current.firm = nil
    application
  end

  it "lapses an unactivated registration after 7 days and frees the mobile, with no email" do
    application = create_registration
    application.update!(submitted_at: 8.days.ago, internal_notes: "ops looked")
    mobile = application.mobile

    expect { described_class.perform_now }.not_to change { ActionMailer::Base.deliveries.size }

    expect(application.reload).to be_lapsed
    expect(application.firm.reload).to be_discarded
    expect(User.across_firms.find_by(mobile:)).to be_nil
    expect(AuditEvent.find_by(action: "onboarding.lapsed", subject: application)).to be_present
  end

  it "hard-deletes a lapsed registration 30 days after it was discarded" do
    application = create_registration(mobile: "+919800000001", email: "gone@example.com")
    application.update!(submitted_at: 8.days.ago)
    described_class.perform_now
    firm_id = application.firm_id
    acceptance_id = application.legal_acceptance.id

    travel 31.days
    described_class.perform_now

    expect(Firm.find_by(id: firm_id)).to be_nil
    expect(OnboardingApplication.across_firms.find_by(id: application.id)).to be_nil
    expect(LegalAcceptance.across_firms.find_by(id: acceptance_id)).to be_nil
  end

  it "keeps an activated firm's acceptance for three years, then deletes it" do
    application = create_registration(mobile: "+919800000002", email: "kept@example.com")
    create(:subscription, firm: application.firm)
    application.firm.activate!
    acceptance = application.legal_acceptance
    acceptance.document.attach(io: StringIO.new("%PDF-1.4\n"), filename: "terms.pdf", content_type: "application/pdf")

    application.firm.destroy!

    acceptance.reload
    expect(acceptance.firm_id).to be_nil
    expect(acceptance.onboarding_application_id).to be_nil
    expect(acceptance.retain_until).to eq(Date.current + 3.years)
    expect(acceptance.document).to be_attached

    Current.firm = create(:firm)
    travel_to(acceptance.retain_until)
    described_class.perform_now
    expect(LegalAcceptance.across_firms.find_by(id: acceptance.id)).to be_nil
  end

  it "does not lapse a registration that has been activated" do
    application = create_registration(mobile: "+919800000003", email: "live@example.com")
    create(:subscription, firm: application.firm)
    application.firm.activate!
    application.update!(submitted_at: 8.days.ago)

    described_class.perform_now

    expect(application.firm.reload).to be_active
    expect(application.firm.discarded_at).to be_nil
  end

  it "still finds the rows when another firm is the current tenant" do
    application = create_registration(mobile: "+919800000004", email: "other@example.com")
    application.update!(submitted_at: 8.days.ago)
    Current.firm = create(:firm)

    described_class.perform_now

    expect(application.reload).to be_lapsed
  end
end
