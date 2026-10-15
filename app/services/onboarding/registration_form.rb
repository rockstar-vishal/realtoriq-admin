# frozen_string_literal: true

module Onboarding
  # The one-page registration. Not a database row: Submit is the only write.
  class RegistrationForm
    include ActiveModel::Model

    ATTRIBUTES = %i[
      applicant_name applicant_designation entity_type firm_name legal_name
      mobile whatsapp email address_line1 address_line2 city_id locality_id pincode
      team_size pan gst rera_registered rera_number rera_valid_till
      rera_declaration accept
    ].freeze

    attr_accessor(*ATTRIBUTES, :extra_locality_ids, :website, :captcha,
      :visiting_card, :rera_certificate, :mobile_code, :whatsapp_code, :email_code,
      :visiting_card_bytes, :visiting_card_type, :visiting_card_name,
      :rera_certificate_bytes, :rera_certificate_type, :rera_certificate_name)

    def self.from_params(params)
      permitted = params.permit(*ATTRIBUTES, extra_locality_ids: [])
      form = new(permitted.to_h)
      form.extra_locality_ids = Array(params[:extra_locality_ids]).reject(&:blank?)
      form.website = params[:website]
      form.captcha = params[:"g-recaptcha-response"]
      form.visiting_card = params[:visiting_card]
      form.rera_certificate = params[:rera_certificate]
      form.mobile_code = params[:mobile_code]
      form.whatsapp_code = params[:whatsapp_code]
      form.email_code = params[:email_code]
      form.normalise
      form
    end

    def normalise
      self.applicant_name = applicant_name.to_s.strip.presence
      self.applicant_designation = applicant_designation.to_s.strip.presence
      self.firm_name = firm_name.to_s.strip.presence
      self.legal_name = legal_name.to_s.strip.presence
      self.address_line1 = address_line1.to_s.strip.presence
      self.address_line2 = address_line2.to_s.strip.presence
      self.pincode = pincode.to_s.strip.presence
      self.entity_type = entity_type.to_s.presence
      self.team_size = team_size.to_s.presence
      self.mobile = Phone.normalise(mobile)
      self.whatsapp = Phone.normalise(whatsapp)
      self.email = email.to_s.downcase.strip.presence
      self.pan = pan.to_s.upcase.strip.presence
      self.gst = gst.to_s.upcase.strip.presence
      self.rera_number = rera_number.to_s.strip.presence
      self.legal_name = applicant_name if entity_type == "individual" && legal_name.blank?
      self.extra_locality_ids = Array(extra_locality_ids).reject(&:blank?).uniq
    end

    def code_for(kind)
      public_send(:"#{kind}_code").to_s.strip
    end

    def rera_yes? = rera_registered.to_s == "true"

    def rera_no? = rera_registered.to_s == "false"

    def validate_for_submit!(sitting)
      normalise
      sitting.sync!(mobile:, email:, whatsapp:)
      require_text
      require_contacts(sitting)
      require_address
      require_tax
      require_rera
      require_files
      errors.add(:accept, "is required") unless accept.to_s == "1"
    end

    private

    def require_text
      errors.add(:applicant_name, "is required") if applicant_name.blank?
      errors.add(:applicant_designation, "is required") if applicant_designation.blank?
      errors.add(:firm_name, "is required") if firm_name.blank?
      errors.add(:entity_type, "is required") unless Onboarding::ENTITY_TYPES.include?(entity_type)
      if team_size.present? && Onboarding::TEAM_SIZES.exclude?(team_size)
        errors.add(:team_size, "isn't a valid choice")
      end
      errors.add(:applicant_name, "is too long") if applicant_name.to_s.length > 160
      errors.add(:firm_name, "is too long") if firm_name.to_s.length > 160
    end

    def require_contacts(sitting)
      check_phone(:mobile, mobile)
      check_phone(:whatsapp, whatsapp)
      errors.add(:email, "enter a valid email address") unless email.to_s.match?(URI::MailTo::EMAIL_REGEXP)
      errors.add(:mobile, Onboarding::VERIFY_AGAIN) unless sitting.verified?(:mobile, mobile)
      errors.add(:email, Onboarding::VERIFY_AGAIN) unless sitting.verified?(:email, email)
      note_conflicts
    end

    def check_phone(field, value)
      return if value.to_s.match?(Onboarding::INDIAN_MOBILE)

      errors.add(field, "enter an Indian mobile number")
    end

    def note_conflicts
      if mobile.present? && User.across_firms.exists?(mobile:)
        errors.add(:mobile, Onboarding::REGISTERED_NUMBER)
      elsif mobile.present? && OnboardingApplication.across_firms.submitted.exists?(mobile:)
        errors.add(:mobile, Onboarding::UNDER_REVIEW_NUMBER)
      end

      if email.present? && User.across_firms.where("lower(email) = ?", email).exists?
        errors.add(:email, Onboarding::REGISTERED_EMAIL)
      elsif email.present? && OnboardingApplication.across_firms.submitted.where("lower(email) = ?", email).exists?
        errors.add(:email, Onboarding::UNDER_REVIEW_EMAIL)
      end

      return if whatsapp.blank?

      if User.across_firms.exists?(mobile: whatsapp)
        errors.add(:whatsapp, Onboarding::REGISTERED_NUMBER)
      elsif OnboardingApplication.across_firms.submitted.exists?(whatsapp:) ||
          OnboardingApplication.across_firms.submitted.exists?(mobile: whatsapp)
        errors.add(:whatsapp, Onboarding::UNDER_REVIEW_NUMBER)
      end
    end

    def require_address
      errors.add(:address_line1, "is required") if address_line1.blank?
      errors.add(:pincode, "must be 6 digits") unless pincode.to_s.match?(/\A\d{6}\z/)
      city = City.find_by(id: city_id)
      locality = Locality.active.find_by(id: locality_id)
      errors.add(:city_id, "is required") if city.nil?
      errors.add(:locality_id, "choose a locality in this city") if locality.nil? || city.nil? || locality.city_id != city.id
      extra_locality_ids.each do |id|
        extra = Locality.active.find_by(id:)
        if extra.nil? || city.nil? || extra.city_id != city.id || extra.id == locality&.id
          errors.add(:extra_locality_ids, "must be other active localities in this city")
          break
        end
      end
    end

    def require_tax
      errors.add(:pan, "is not a valid PAN") if pan.present? && !pan.match?(Onboarding::PAN_FORMAT)
      errors.add(:gst, "is not a valid GSTIN") if gst.present? && !gst.match?(Onboarding::GSTIN_FORMAT)
      return if pan.blank? || gst.blank?
      return if gst[2, 10] == pan

      errors.add(:gst, "does not match the PAN")
    end

    def require_rera
      if rera_yes?
        errors.add(:rera_number, "is required") unless rera_number.to_s.match?(Onboarding::RERA_FORMAT)
        date = parse_date(rera_valid_till)
        errors.add(:rera_valid_till, "must be in the future") if date.nil? || date <= Date.current
      elsif rera_no?
        errors.add(:rera_declaration, "is required") unless rera_declaration.to_s == "1"
      else
        errors.add(:rera_registered, "choose yes or no")
      end
    end

    def require_files
      read_file(:visiting_card, required: true)
      read_file(:rera_certificate, required: rera_yes?)
    end

    def read_file(field, required:)
      upload = public_send(field)
      if upload.blank?
        errors.add(field, "is required") if required
        return
      end
      unless upload.respond_to?(:tempfile) && upload.respond_to?(:size)
        errors.add(field, "must be a PDF or an image")
        return
      end
      if upload.size > Onboarding::MAX_FILE_BYTES
        errors.add(field, "must be 2 MB or smaller")
        return
      end

      upload.tempfile.rewind
      bytes = upload.tempfile.read
      upload.tempfile.rewind
      type = Marcel::MimeType.for(StringIO.new(bytes))
      unless Onboarding::FILE_TYPES.include?(type)
        errors.add(field, "must be a PDF or an image")
        return
      end

      public_send(:"#{field}_bytes=", bytes)
      public_send(:"#{field}_type=", type == "image/heif" ? "image/heic" : type)
      public_send(:"#{field}_name=", upload.original_filename.to_s)
    end

    def parse_date(value)
      return value if value.is_a?(Date)
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
