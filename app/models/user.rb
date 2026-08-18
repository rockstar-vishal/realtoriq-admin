# frozen_string_literal: true

# A broker user inside a firm.
#
# Note what is absent: no password. Brokers sign in with a one-time code sent to
# their mobile, and accounts are created for them by ops — the design is
# explicit that there is no self-signup anywhere in the product.
class User < ApplicationRecord
  include FirmScoped

  ROLES = %w[super_admin manager agent].freeze
  STATUSES = %w[active disabled].freeze
  NOTIFICATION_MODES = %w[all important none].freeze

  MAX_FAILED_OTP_ATTEMPTS = 3
  LOCKOUT_DURATION = 30.minutes

  enum :role, ROLES.index_by(&:itself), validate: true
  enum :status, STATUSES.index_by(&:itself), validate: true

  validates :name, presence: true, length: { maximum: 120 }
  validates :mobile, presence: true, uniqueness: true, format: {
    with: /\A\+\d{10,15}\z/,
    message: "must be in international format, e.g. +919820144210"
  }
  validates :email, uniqueness: { case_sensitive: false }, allow_blank: true, format: {
    with: URI::MailTo::EMAIL_REGEXP
  }, if: -> { email.present? }
  validates :notification_mode, inclusion: { in: NOTIFICATION_MODES }

  # Unscoped, because sessions are created and evicted during sign-in — before
  # Current.firm exists. Safe: scoping by user_id already implies exactly one
  # firm, since a user belongs to exactly one.
  #
  # Note the asymmetry with firm.users, which needs no such treatment: there the
  # association's foreign key IS firm_id, so Rails replaces the default scope's
  # condition with it. Here the key is user_id, so `firm_id IS NULL` survives
  # and the association silently returns nothing.
  has_many :auth_sessions, -> { unscope(where: :firm_id) }, dependent: :destroy

  # A broker leaving must not take the firm's pipeline with them — their leads
  # are unassigned and stay, and the timeline keeps what happened while ceasing
  # to name who.
  #
  # No `dependent:` here on purpose: the foreign keys carry ON DELETE SET NULL
  # (see NullifyUserReferencesOnDelete). LeadStatusChange is readonly at the
  # application layer, so Active Record could not null it anyway, and a database
  # constraint also holds for deletes that never touch Ruby.
  has_many :assigned_leads, -> { unscope(where: :firm_id) },
    class_name: "Lead", foreign_key: :assigned_user_id, inverse_of: :assigned_user

  before_validation :normalise_contact_details

  scope :active_first, -> { order(Arel.sql("CASE WHEN status = 'active' THEN 0 ELSE 1 END"), :name) }

  # The sign-in screen has no subdomain or firm code to narrow by, so the mobile
  # alone has to resolve a user — which is why it is globally unique.
  def self.find_for_sign_in(mobile:)
    across_firms.find_by(mobile: Phone.normalise(mobile))
  end

  def locked_out?
    otp_locked_until.present? && otp_locked_until.future?
  end

  def register_failed_otp_attempt!
    increment!(:failed_otp_attempts)
    return unless failed_otp_attempts >= MAX_FAILED_OTP_ATTEMPTS

    update!(otp_locked_until: LOCKOUT_DURATION.from_now, failed_otp_attempts: 0)
  end

  def clear_otp_lockout!
    update!(failed_otp_attempts: 0, otp_locked_until: nil)
  end

  def can_manage_firm_settings? = super_admin?

  private

  def normalise_contact_details
    self.mobile = Phone.normalise(mobile)
    self.email = email.to_s.downcase.strip.presence
  end
end
