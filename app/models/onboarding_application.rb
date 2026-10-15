# frozen_string_literal: true

# A broker's submitted registration. Created in the same transaction as the
# pending firm. Status leaves "submitted" on reject or lapse so the same mobile
# can register again.
class OnboardingApplication < ApplicationRecord
  include FirmScoped

  STATUSES = %w[submitted rejected lapsed].freeze

  enum :status, STATUSES.index_by(&:itself), validate: true
  enum :entity_type, Onboarding::ENTITY_TYPES.index_by(&:itself), validate: true
  enum :team_size, Onboarding::TEAM_SIZES.index_by(&:itself), validate: { allow_nil: true }

  belongs_to :city
  belongs_to :locality
  belongs_to :reviewed_by_admin, class_name: "AdminUser", optional: true
  has_one :legal_acceptance, -> { unscope(where: :firm_id) }, inverse_of: :onboarding_application
  has_one_attached :visiting_card, dependent: :purge_later
  has_one_attached :rera_certificate, dependent: :purge_later

  validates :reference, :applicant_name, :applicant_designation, :firm_name,
    :address_line1, :pincode, :submitted_at, :captcha_verified_at, presence: true
  validates :applicant_name, :applicant_designation, :firm_name, length: { maximum: 160 }
  validates :legal_name, length: { maximum: 160 }, allow_blank: true
  validates :address_line1, :address_line2, length: { maximum: 200 }, allow_blank: true
  validates :pincode, format: { with: /\A\d{6}\z/ }
  validates :mobile, :whatsapp, format: { with: Onboarding::INDIAN_MOBILE }
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :pan, format: { with: Onboarding::PAN_FORMAT }, allow_blank: true
  validates :gst_number, format: { with: Onboarding::GSTIN_FORMAT }, allow_blank: true
  validates :rera_number, format: { with: Onboarding::RERA_FORMAT }, allow_blank: true
  validates :mobile_verified_at, :email_verified_at, presence: true
  validate :gst_matches_pan
  validate :rera_details
  validate :locality_in_city

  before_validation :normalise_fields

  scope :matching, ->(term) {
    next all if term.blank?

    pattern = "%#{sanitize_sql_like(term.to_s.strip)}%"
    table = connection.quote_table_name(table_name)
    columns = %w[reference applicant_name firm_name legal_name mobile email pan gst_number rera_number]
    where(columns.map { |column| "#{table}.#{connection.quote_column_name(column)} ILIKE :q" }.join(" OR "), q: pattern)
  }

  scope :awaiting, -> {
    submitted.joins(:firm).where(firms: { status: "pending", discarded_at: nil })
  }

  scope :activated, -> { joins(:firm).where.not(firms: { activated_at: nil }) }
  scope :queue_rejected, -> { where(status: "rejected") }
  scope :queue_lapsed, -> { where(status: "lapsed") }

  def self.generate_reference
    alphabet = Onboarding::REFERENCE_ALPHABET
    8.times do
      candidate = "RIQ-" + Array.new(8) { alphabet[SecureRandom.random_number(alphabet.length)] }.join
      return candidate unless across_firms.exists?(reference: candidate)
    end

    raise ActiveRecord::RecordNotUnique, "reference"
  end

  def to_param = reference

  def days_until_lapse
    return 0 if submitted_at.blank?

    remaining = submitted_at + 7.days - Time.current
    [ (remaining / 1.day).ceil, 0 ].max
  end

  def duplicates
    firm_duplicates + user_duplicates + application_duplicates
  end

  private

  def normalise_fields
    self.mobile = Phone.normalise(mobile)
    self.whatsapp = Phone.normalise(whatsapp)
    self.email = email.to_s.downcase.strip.presence
    self.pan = pan.to_s.upcase.strip.presence
    self.gst_number = gst_number.to_s.upcase.strip.presence
    self.applicant_name = applicant_name.to_s.strip.presence
    self.applicant_designation = applicant_designation.to_s.strip.presence
    self.firm_name = firm_name.to_s.strip.presence
    self.legal_name = legal_name.to_s.strip.presence
    self.rera_number = rera_number.to_s.strip.presence
    self.pincode = pincode.to_s.strip.presence
  end

  def gst_matches_pan
    return if pan.blank? || gst_number.blank?
    return if gst_number[2, 10] == pan

    errors.add(:gst_number, "does not match the PAN")
  end

  def rera_details
    if rera_registered?
      errors.add(:rera_number, "is required") if rera_number.blank?
      errors.add(:rera_valid_till, "must be in the future") if rera_valid_till.blank? || rera_valid_till <= Date.current
    elsif rera_declared_at.blank?
      errors.add(:rera_declared_at, "is required when there is no RERA registration")
    end
  end

  def locality_in_city
    return if locality.blank? || city.blank?
    return if locality.city_id == city_id && locality.active?

    errors.add(:locality_id, "must be an active locality in the chosen city")
  end

  def firm_duplicates
    clauses = []
    binds = {}
    if pan.present?
      clauses << "pan = :pan"
      binds[:pan] = pan
    end
    if gst_number.present?
      clauses << "gst_number = :gst"
      binds[:gst] = gst_number
    end
    if rera_number.present?
      clauses << "rera_number = :rera"
      binds[:rera] = rera_number
    end
    if firm_name.present?
      clauses << "trim(both '-' from regexp_replace(lower(firms.name), '[^a-z0-9]+', '-', 'g')) = :slug"
      binds[:slug] = firm_name.parameterize
    end
    return [] if clauses.empty?

    Firm.where.not(id: firm_id).where(clauses.join(" OR "), binds).pluck(:slug, :name).map do |slug, name|
      { kind: "Firm", label: name, firm_slug: slug, reference: nil, reason: "same details" }
    end
  end

  def user_duplicates
    ids = User.across_firms.where.not(firm_id:).where(mobile: [ mobile, whatsapp ].compact).pluck(:firm_id)
    if email.present?
      ids += User.across_firms.where.not(firm_id:).where("lower(email) = ?", email.downcase).pluck(:firm_id)
    end
    ids += ContactChannel.across_firms.where.not(firm_id:).where(value: [ mobile, whatsapp, email ].compact).pluck(:firm_id)
    Firm.where(id: ids.uniq).pluck(:slug, :name).map do |slug, name|
      { kind: "User", label: name, firm_slug: slug, reference: nil, reason: "same contact" }
    end
  end

  def application_duplicates
    parts = [ "mobile = :mobile", "whatsapp = :whatsapp" ]
    binds = { mobile:, whatsapp: }
    if email.present?
      parts << "lower(email) = :email"
      binds[:email] = email.downcase
    end
    if pan.present?
      parts << "pan = :pan"
      binds[:pan] = pan
    end
    if gst_number.present?
      parts << "gst_number = :gst"
      binds[:gst] = gst_number
    end
    if rera_number.present?
      parts << "rera_number = :rera"
      binds[:rera] = rera_number
    end

    self.class.across_firms.where.not(id:).where(parts.join(" OR "), binds).pluck(:reference, :firm_name).map do |reference, name|
      { kind: "Application", label: name, firm_slug: nil, reference:, reason: "same details" }
    end
  end
end
