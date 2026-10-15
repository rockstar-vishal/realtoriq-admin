# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Public registration" do
  let(:city) { create(:city, name: "Pune") }
  let(:locality) { create(:locality, city:, name: "Kothrud") }

  it "renders for an old Android browser and leaves Submit usable without JavaScript" do
    get "/self-signup", headers: {
      "User-Agent" => "Mozilla/5.0 (Linux; Android 8.0.0; SM-G950F) AppleWebKit/537.36 Chrome/60.0.3112.107 Mobile Safari/537.36"
    }

    expect(response).to have_http_status(:ok)
    button = Nokogiri::HTML(response.body).at_css("button.su-btn-lg")
    expect(button["disabled"]).to be_nil
    expect(button.text).to include("Submit registration")
    expect(response.body).to include('target="_blank"')
  end

  it "404s registration and legal pages on a firm host" do
    firm = create(:firm)
    host! "cp-#{firm.slug}.realtoriq.kgen.tech"

    get "/self-signup"
    expect(response).to have_http_status(:not_found)

    get "/register"
    expect(response).to have_http_status(:not_found)

    get "/legal/terms"
    expect(response).to have_http_status(:not_found)
  end

  it "serves the pinned terms, and embed=1 is the document alone" do
    get "/legal/terms"

    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("max-age=300")
    expect(response.headers["X-Robots-Tag"]).to eq("noindex")
    expect(response.body).to include("Limitation of liability")

    get "/legal/terms", params: { embed: "1" }
    expect(response.body).to include('class="su-embed"')
    expect(response.body).not_to include("Register your firm")
    expect(response.body).to include("Limitation of liability")
  end

  it "creates a pending firm once mobile and email are verified" do
    verify_registration_contact("mobile", "9876543210")
    verify_registration_contact("email", "asha@example.com")

    expect {
      post "/self-signup", params: registration_fields(city:, locality:)
    }.to change(Firm, :count).by(1)
      .and have_enqueued_job(Onboarding::FinalizeSubmissionJob)
      .and have_enqueued_mail(OnboardingMailer, :new_application)

    expect(response).to redirect_to(registration_submitted_path)
    follow_redirect!
    application = OnboardingApplication.across_firms.order(:created_at).last
    expect(response.body).to include(application.reference)

    firm = application.firm
    expect(firm).to be_pending
    expect(firm.website_enabled).to be(true)
    expect(firm.internal_notes).to eq("Registered online, ref #{application.reference}")
    expect(firm.users.sole).to be_super_admin
    expect(firm.contact_channels.find_by(kind: "whatsapp")).not_to be_verified
    expect(firm.contact_channels.find_by(kind: "mobile")).to be_verified
    expect(firm.contact_channels.find_by(kind: "mobile").verification_attempts).to eq(0)

    acceptance = application.legal_acceptance
    expect(acceptance.statement).to eq(Onboarding::ACCEPTANCE_STATEMENT)
    expect(acceptance.terms_sha256).to eq(Legal::Registry.current(:terms).sha256)
    expect(acceptance.evidence["whatsapp_verified_at"]).to be_nil
    expect(acceptance.ip).to eq("127.0.0.1")

    other = create(:firm)
    Current.firm = other
    expect { OnboardingApplication.find(application.id) }.to raise_error(ActiveRecord::RecordNotFound)
    expect(OnboardingApplication.across_firms.find(application.id)).to eq(application)

    perform_enqueued_jobs
    expect(acceptance.reload.pdf_sha256).to eq(Digest::SHA256.hexdigest(acceptance.document.download))
    reader = PDF::Reader.new(StringIO.new(acceptance.document.download))
    text = reader.pages.map(&:text).join("\n")
    expect(text).to include(application.reference, firm.name, acceptance.terms_sha256, "21. Limitation of liability", "13. Grievance Officer")
    expect(text).to include("#{application.whatsapp}, not verified")

    delivered = ActionMailer::Base.deliveries.size
    Onboarding::FinalizeSubmissionJob.perform_now(acceptance.id)
    expect(ActionMailer::Base.deliveries.size).to eq(delivered)
  end

  it "refuses submit until mobile and email are verified" do
    post "/self-signup", params: registration_fields(city:, locality:)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include(Onboarding::VERIFY_AGAIN)
    expect(Firm.count).to eq(0)
  end

  it "does not create a firm when the honeypot or captcha fails" do
    verify_registration_contact("mobile", "9876543210")
    verify_registration_contact("email", "asha@example.com")

    post "/self-signup", params: registration_fields(city:, locality:, website: "http://spam.example")
    expect(Firm.count).to eq(0)

    post "/self-signup", params: registration_fields(city:, locality:, "g-recaptcha-response": "nope")
    expect(response.body).to include("not a robot")
    expect(Firm.count).to eq(0)
  end

  it "refuses a file over 2 MB and a renamed non-image" do
    verify_registration_contact("mobile", "9876543210")
    verify_registration_contact("email", "asha@example.com")

    post "/self-signup", params: registration_fields(city:, locality:, visiting_card: upload_bytes("a" * 2.1.megabytes, name: "big.png", type: "image/png"))
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("2 MB")
    expect(response.body).to include("add your visiting card")
    expect(Firm.count).to eq(0)

    post "/self-signup", params: registration_fields(
      city:, locality:, visiting_card: upload_bytes("hello", name: "card.pdf", type: "application/pdf")
    )
    expect(response.body).to include("PDF or an image")
    expect(Firm.count).to eq(0)
  end

  it "refuses a submit whose content length is over 5 MB before creating a firm" do
    post "/self-signup", params: { blob: "x" * (5.megabytes + 1) }

    expect(response).to have_http_status(:content_too_large)
    expect(Firm.count).to eq(0)
  end

  it "tells a registered mobile to sign in, and a submitted one that it is under review" do
    create(:user, mobile: "+919876543210")
    post registration_send_code_path(kind: "mobile"), params: { mobile: "9876543210" }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include(Onboarding::REGISTERED_NUMBER)

    firm = create(:firm, :pending)
    Current.firm = firm
    OnboardingApplication.create!(
      firm:, reference: "RIQ-TESTONLY", status: "submitted",
      applicant_name: "A", applicant_designation: "Owner", mobile: "+919000000001", whatsapp: "+919000000002",
      email: "taken@example.com", mobile_verified_at: Time.current, email_verified_at: Time.current,
      entity_type: "individual", firm_name: "Taken", legal_name: "A", rera_registered: false,
      rera_declared_at: Time.current, address_line1: "1 Road", city:, locality:, pincode: "411001",
      submitted_at: Time.current, captcha_verified_at: Time.current
    )
    Current.firm = nil

    post registration_send_code_path(kind: "email"), params: { email: "taken@example.com" }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include(Onboarding::UNDER_REVIEW_EMAIL)
  end

  it "does not accept a code that was sent to a different number" do
    post registration_send_code_path(kind: "mobile"), params: { mobile: "9876543210" }
    code = deliverer.last.code

    post registration_verify_code_path(kind: "mobile"), params: { mobile: "9876543212", mobile_code: code }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("or it has expired")
  end

  it "lets the same mobile register again after the first application is rejected" do
    verify_registration_contact("mobile", "9876543210")
    verify_registration_contact("email", "asha@example.com")
    post "/self-signup", params: registration_fields(city:, locality:)
    application = OnboardingApplication.across_firms.order(:created_at).last
    expect(Onboarding::Reject.call(application:, admin: create(:admin_user), reason: "Unreadable card")).to be(true)
    expect(application.reload).to be_rejected

    verify_registration_contact("mobile", "9876543210")
    verify_registration_contact("email", "asha@example.com")
    expect {
      post "/self-signup", params: registration_fields(city:, locality:)
    }.to change(Firm, :count).by(1)
    expect(response).to redirect_to(registration_submitted_path)
  end

  it "uses proper entity labels and keeps every contact button in the page" do
    get "/self-signup"
    document = Nokogiri::HTML(response.body)

    labels = document.css(".su-chip span").map(&:text)
    expect(labels).to include("LLP", "Private Limited", "Public Limited")
    expect(labels).not_to include("Llp")
    expect(document.at_css("#legal_name")["required"]).to be_nil
    expect(response.body).to include("optional")
    expect(document.at_css('.su-reveal[data-when="true"]')).to be_present
    expect(document.at_css('.su-reveal[data-when="false"]')).to be_present
    expect(document.at_css("#contact-mobile")["data-state"]).to eq("idle")
    expect(document.at_css('button[formaction*="mobile/verify"]')).to be_present
  end

  it "marks a contact sent after a code, and leaves the others idle" do
    post registration_send_code_path(kind: "mobile"), params: { mobile: "9876543210" }
    expect(response).to have_http_status(:ok)
    document = Nokogiri::HTML(response.body)

    expect(document.at_css("#contact-mobile")["data-state"]).to eq("sent")
    expect(document.at_css("#contact-email")["data-state"]).to eq("idle")
    expect(document.at_css("#mobile_code")).to be_present
  end

  it "sends the same unused code again for 10 minutes" do
    post registration_send_code_path(kind: "mobile"), params: { mobile: "9876543210" }
    first = deliverer.last.code

    travel 2.minutes
    post registration_send_code_path(kind: "mobile"), params: { mobile: "9876543210" }

    expect(deliverer.last.code).to eq(first)
    expect(OneTimeCode.count).to eq(1)

    travel 11.minutes
    post registration_send_code_path(kind: "mobile"), params: { mobile: "9876543210" }
    expect(OneTimeCode.count).to eq(2)
  end

  it "accepts a partnership with no legal name" do
    verify_registration_contact("mobile", "9876543210")
    verify_registration_contact("email", "asha@example.com")

    expect {
      post "/self-signup", params: registration_fields(city:, locality:, legal_name: "")
    }.to change(Firm, :count).by(1)

    application = OnboardingApplication.across_firms.order(:created_at).last
    expect(application.legal_name).to be_nil
    expect(application.firm.legal_name).to be_nil
  end

  it "keeps verified mobile and email, with their values, on the next visit" do
    verify_registration_contact("mobile", "9876543210")
    verify_registration_contact("email", "asha@example.com")

    get "/self-signup"
    document = Nokogiri::HTML(response.body)

    expect(document.at_css("#contact-mobile")["data-state"]).to eq("verified")
    expect(document.at_css("#contact-email")["data-state"]).to eq("verified")
    expect(document.at_css("#mobile")["value"]).to eq("9876543210")
    expect(document.at_css("#email")["value"]).to eq("asha@example.com")
  end

  it "drops the old mobile tick when the number is changed and a code is sent again" do
    verify_registration_contact("mobile", "9876543210")

    post registration_change_contact_path(kind: "mobile"), params: { mobile: "9876543210" }
    expect(response).to have_http_status(:ok)

    post registration_send_code_path(kind: "mobile"), params: { mobile: "9876543212" }
    expect(response).to have_http_status(:ok)

    get "/self-signup"
    document = Nokogiri::HTML(response.body)
    expect(document.at_css("#contact-mobile")["data-state"]).to eq("sent")
    expect(document.at_css("#mobile")["value"]).to eq("9876543212")
  end

  it "returns the other typed fields when a code is sent without JavaScript" do
    post registration_send_code_path(kind: "mobile"), params: {
      mobile: "9876543210",
      applicant_name: "Asha Kulkarni",
      firm_name: "Kulkarni Estates",
      email: "asha@example.com",
      address_line1: "12 MG Road"
    }

    expect(response).to have_http_status(:ok)
    document = Nokogiri::HTML(response.body)
    expect(document.at_css("#applicant_name")["value"]).to eq("Asha Kulkarni")
    expect(document.at_css("#firm_name")["value"]).to eq("Kulkarni Estates")
    expect(document.at_css("#email")["value"]).to eq("asha@example.com")
    expect(document.at_css("#address_line1")["value"]).to eq("12 MG Road")
  end

  it "does not put the typed fields in a cookie" do
    typed = { applicant_name: "Asha Kulkarni", firm_name: "Kulkarni Estates", address_line1: "12 MG Road" }

    post registration_send_code_path(kind: "mobile"), params: typed.merge(mobile: "9876543210")
    expect(registration_cookie_text).not_to include("Asha Kulkarni")
    expect(registration_cookie_text).not_to include("Kulkarni Estates")
    expect(registration_cookie_text).not_to include("12 MG Road")

    post registration_verify_code_path(kind: "mobile"), params: typed.merge(mobile: "9876543210", mobile_code: deliverer.last.code)
    expect(registration_cookie_text).not_to include("Asha Kulkarni")

    post registration_change_contact_path(kind: "email"), params: typed.merge(email: "asha@example.com")
    expect(registration_cookie_text).not_to include("Kulkarni Estates")

    get "/self-signup"
    document = Nokogiri::HTML(response.body)
    expect(document.at_css("#applicant_name")["value"]).to be_blank
    expect(document.at_css("#firm_name")["value"]).to be_blank
    expect(registration_cookie_text).not_to include("Asha Kulkarni")

    post "/self-signup", params: registration_fields(city:, locality:)
    expect(registration_cookie_text).not_to include("Asha Kulkarni")
    expect(registration_cookie_text).not_to include("Kulkarni Estates")
    expect(registration_cookie_text).not_to include("12 MG Road")
  end

  def registration_cookie_text
    verify = ActionDispatch::Cookies::CookieJar.build(request, cookies.to_hash).encrypted[:riq_verify]
    [ session.to_hash, verify ].join
  end

  describe "JSON verification" do
    def json_post(path, params)
      post path, params:, headers: { "Accept" => "application/json" }
    end

    it "returns a sent state and a resend window of at most 60 seconds" do
      json_post registration_send_code_path(kind: "mobile"), { mobile: "9876543210" }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["ok"]).to be(true)
      expect(body["state"]).to eq("sent")
      expect(body["message"]).to eq("Code sent by SMS to +91 98765 43210.")
      expect(body["resend_in"]).to be_between(0, 60)
    end

    it "rejects a wrong code while the contact stays sent" do
      json_post registration_send_code_path(kind: "mobile"), { mobile: "9876543210" }
      code = deliverer.last.code
      wrong = code == "000000" ? "111111" : "000000"

      json_post registration_verify_code_path(kind: "mobile"), { mobile: "9876543210", mobile_code: wrong }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["ok"]).to be(false)
      expect(response.parsed_body["state"]).to eq("sent")
    end

    it "returns verified for the right code" do
      json_post registration_send_code_path(kind: "mobile"), { mobile: "9876543210" }
      json_post registration_verify_code_path(kind: "mobile"), { mobile: "9876543210", mobile_code: deliverer.last.code }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["ok"]).to be(true)
      expect(response.parsed_body["state"]).to eq("verified")
    end

    it "returns idle and clears the tick when the number is changed" do
      json_post registration_send_code_path(kind: "mobile"), { mobile: "9876543210" }
      json_post registration_verify_code_path(kind: "mobile"), { mobile: "9876543210", mobile_code: deliverer.last.code }
      json_post registration_change_contact_path(kind: "mobile"), { mobile: "9876543210" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("ok" => true, "state" => "idle", "message" => "")

      get "/self-signup"
      expect(Nokogiri::HTML(response.body).at_css("#contact-mobile")["data-state"]).to eq("idle")
    end
  end
end
