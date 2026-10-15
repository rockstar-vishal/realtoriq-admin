# frozen_string_literal: true

module Onboarding
  # Creates the pending firm, its super admin, channels, acceptance and
  # application in one transaction. The firm is saved first so Current.firm
  # is set before any FirmScoped row is written.
  class Submit
    Result = Struct.new(:ok, :application, keyword_init: true)

    def initialize(form:, sitting:, request:)
      @form = form
      @sitting = sitting
      @request = request
    end

    def call
      if form.website.to_s.strip.present?
        form.errors.add(:base, "We couldn't submit that. Please try again.")
        return Result.new(ok: false)
      end
      return refuse("Please confirm you are not a robot.") unless captcha_accepted?

      form.validate_for_submit!(sitting)
      return Result.new(ok: false) if form.errors.any?
      return refuse(Onboarding::TOO_MANY) unless Throttle.allow_submit?(request.remote_ip)

      application = create_records
      return Result.new(ok: false) if application.nil?

      FinalizeSubmissionJob.perform_later(application.legal_acceptance.id)
      OnboardingMailer.new_application(application.id).deliver_later
      Result.new(ok: true, application:)
    ensure
      Current.firm = nil
    end

    private

    attr_reader :form, :sitting, :request

    def captcha_accepted?
      Sites::Recaptcha.accepted?(form.captcha, remote_ip: request.remote_ip, hostname: request.host)
    end

    def refuse(message)
      form.errors.add(:base, message)
      Result.new(ok: false)
    end

    def create_records
      attempts = 0
      begin
        attempts += 1
        insert_records
      rescue ActiveRecord::RecordNotUnique => e
        retry if e.message.include?("reference") && attempts < 5

        form.errors.add(:base, unique_message(e))
        nil
      rescue ActiveRecord::RecordInvalid => e
        form.errors.add(:base, e.record.errors.full_messages.to_sentence)
        nil
      end
    end

    def insert_records
      application = nil
      Firm.transaction do
        firm = build_firm
        firm.save!
        Current.firm = firm
        Current.request_ip = request.remote_ip
        user = firm.users.create!(name: form.applicant_name, mobile: form.mobile, email: form.email, role: :super_admin)
        create_channels(firm, user)
        create_extra_localities(firm)
        application = create_application(firm)
        create_acceptance(application)
        attach_files(application)
        AuditEvent.record!(subject: firm, action: "firm.created", firm:)
        AuditEvent.record!(subject: application, action: "onboarding.submitted", firm:)
      end
      application
    end

    def build_firm
      Firm.new(
        name: form.firm_name,
        legal_name: form.legal_name,
        status: :pending,
        primary_contact_name: form.applicant_name,
        rera_number: form.rera_yes? ? form.rera_number : nil,
        rera_valid_till: form.rera_yes? ? form.rera_valid_till : nil,
        pan: form.pan,
        gst_number: form.gst,
        address_line1: form.address_line1,
        address_line2: form.address_line2,
        city_id: form.city_id,
        locality_id: form.locality_id,
        pincode: form.pincode,
        website_enabled: true,
        internal_notes: nil
      )
    end

    def create_channels(firm, user)
      firm.contact_channels.create!(
        kind: :mobile, value: form.mobile, verification_state: :verified,
        verified_at: sitting.verified_time(:mobile), verified_by_user: user, verification_attempts: 0
      )
      whatsapp_verified = sitting.verified?(:whatsapp, form.whatsapp)
      firm.contact_channels.create!(
        kind: :whatsapp, value: form.whatsapp,
        verification_state: whatsapp_verified ? :verified : :unverified,
        verified_at: whatsapp_verified ? sitting.verified_time(:whatsapp) : nil,
        verified_by_user: whatsapp_verified ? user : nil,
        verification_attempts: 0
      )
      firm.contact_channels.create!(
        kind: :email, value: form.email, verification_state: :verified,
        verified_at: sitting.verified_time(:email), verified_by_user: user, verification_attempts: 0
      )
    end

    def create_extra_localities(firm)
      form.extra_locality_ids.each do |locality_id|
        firm.firm_localities.create!(locality_id:)
      end
    end

    def create_application(firm)
      now = Time.current
      application = firm.create_onboarding_application!(
        reference: OnboardingApplication.generate_reference,
        status: :submitted,
        applicant_name: form.applicant_name,
        applicant_designation: form.applicant_designation,
        mobile: form.mobile,
        whatsapp: form.whatsapp,
        email: form.email,
        mobile_verified_at: sitting.verified_time(:mobile),
        whatsapp_verified_at: sitting.verified?(:whatsapp, form.whatsapp) ? sitting.verified_time(:whatsapp) : nil,
        email_verified_at: sitting.verified_time(:email),
        entity_type: form.entity_type,
        firm_name: form.firm_name,
        legal_name: form.legal_name,
        pan: form.pan,
        gst_number: form.gst,
        team_size: form.team_size,
        rera_registered: form.rera_yes?,
        rera_number: form.rera_yes? ? form.rera_number : nil,
        rera_valid_till: form.rera_yes? ? form.rera_valid_till : nil,
        rera_declared_at: form.rera_no? ? now : nil,
        address_line1: form.address_line1,
        address_line2: form.address_line2,
        city_id: form.city_id,
        locality_id: form.locality_id,
        pincode: form.pincode,
        extra_locality_ids: form.extra_locality_ids,
        submitted_at: now,
        submit_ip: request.remote_ip,
        submit_user_agent: request.user_agent.to_s.first(300),
        created_ip: request.remote_ip,
        captcha_verified_at: now
      )
      firm.update!(internal_notes: "Registered online, ref #{application.reference}")
      application
    end

    def create_acceptance(application)
      terms = Legal::Registry.current(:terms)
      privacy = Legal::Registry.current(:privacy)
      application.create_legal_acceptance!(
        firm: application.firm,
        terms_version: terms.version,
        terms_sha256: terms.sha256,
        privacy_version: privacy.version,
        privacy_sha256: privacy.sha256,
        statement: Onboarding::ACCEPTANCE_STATEMENT,
        accepted_at: Time.current,
        ip: request.remote_ip,
        user_agent: request.user_agent.to_s.first(300),
        evidence: {
          "mobile" => application.mobile,
          "mobile_verified_at" => application.mobile_verified_at.iso8601,
          "whatsapp" => application.whatsapp,
          "whatsapp_verified_at" => application.whatsapp_verified_at&.iso8601,
          "email" => application.email,
          "email_verified_at" => application.email_verified_at.iso8601,
          "rera_declaration" => application.rera_declared_at.present? ? Onboarding::RERA_DECLARATION : nil
        }
      )
    end

    def attach_files(application)
      application.visiting_card.attach(io: StringIO.new(form.visiting_card_bytes), filename: safe_name(form.visiting_card_name, "visiting-card"), content_type: form.visiting_card_type)
      return unless form.rera_yes?

      application.rera_certificate.attach(io: StringIO.new(form.rera_certificate_bytes), filename: safe_name(form.rera_certificate_name, "rera-certificate"), content_type: form.rera_certificate_type)
    end

    def safe_name(name, fallback)
      cleaned = name.to_s.gsub(/[^\w.\-]+/, "_").sub(/\A_+/, "")
      cleaned.presence || fallback
    end

    def unique_message(error)
      text = error.message
      if text.include?("mobile")
        text.include?("users") ? Onboarding::REGISTERED_NUMBER : Onboarding::UNDER_REVIEW_NUMBER
      elsif text.include?("email")
        text.include?("users") ? Onboarding::REGISTERED_EMAIL : Onboarding::UNDER_REVIEW_EMAIL
      else
        "An application with this number or email is already under review."
      end
    end
  end
end
