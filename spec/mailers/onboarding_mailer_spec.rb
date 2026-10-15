# frozen_string_literal: true

require "rails_helper"

RSpec.describe OnboardingMailer do
  it "loads a registration while another firm is the current tenant" do
    city = create(:city, name: "Pune")
    locality = create(:locality, city:)
    firm = create(:firm, :pending, city:, locality:, name: "Kulkarni Estates")
    Current.firm = firm
    application = OnboardingApplication.create!(
      firm:, reference: OnboardingApplication.generate_reference, status: "submitted",
      applicant_name: "Asha Kulkarni", applicant_designation: "Partner",
      mobile: "+919812345670", whatsapp: "+919812345671", email: "asha@example.com",
      mobile_verified_at: Time.current, email_verified_at: Time.current,
      entity_type: "partnership", firm_name: firm.name, legal_name: firm.legal_name,
      rera_registered: false, rera_declared_at: Time.current,
      address_line1: "12 MG Road", city:, locality:, pincode: "411001",
      submitted_at: Time.current, captcha_verified_at: Time.current
    )
    Current.firm = create(:firm)

    mail = described_class.new_application(application.id)

    expect(mail.subject).to include("Kulkarni Estates")
    expect(mail.body.encoded).to include(application.reference)
    expect(Current.firm).to be_nil
  end
end
