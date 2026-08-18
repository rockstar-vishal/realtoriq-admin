# frozen_string_literal: true

# A firm's verifiable contact point. Three per firm: email, mobile, whatsapp.
#
# These are the firm's, not any individual user's — see the migration for why.
class ContactChannel < ApplicationRecord
  include FirmScoped

  KINDS = %w[email mobile whatsapp].freeze
  STATES = %w[unverified pending verified failed].freeze

  CODE_TTL = 10.minutes
  RESEND_COOLDOWN = 60.seconds
  MAX_ATTEMPTS = 5

  enum :kind, KINDS.index_by(&:itself), validate: true
  enum :verification_state, STATES.index_by(&:itself), prefix: :verification, validate: true

  # Unscoped like the other belongs_to associations into User: a scoped target
  # resolves to nil whenever no tenant is set, and this is read for display in
  # contexts that don't establish one. Safe — the channel is already firm-scoped,
  # so whoever verified it is necessarily in the same firm.
  belongs_to :verified_by_user, -> { unscope(where: :firm_id) },
    class_name: "User", optional: true

  validates :kind, uniqueness: { scope: :firm_id }
  validates :value, presence: true
  validate :value_matches_kind

  before_validation :normalise_value

  scope :ordered, -> { in_order_of(:kind, KINDS) }

  def verified? = verification_verified?

  def phone? = mobile? || whatsapp?

  # Which transport carries this channel's code. Email goes through Action
  # Mailer; the other two go through MSG91.
  def delivery_transport
    case kind
    when "email" then :email
    when "mobile" then :sms
    when "whatsapp" then :whatsapp
    end
  end

  def resend_available_at
    return nil if last_code_sent_at.blank?

    last_code_sent_at + RESEND_COOLDOWN
  end

  def resend_throttled? = resend_available_at.present? && resend_available_at.future?

  def display_value
    phone? ? Phone.format_for_display(value) : value
  end

  # Marking verified by ops carries no user; done from the broker app it carries
  # the super_admin who did it. Either way the badge is the same.
  def mark_verified!(by: nil)
    update!(
      verification_state: :verified,
      verified_at: Time.current,
      verified_by_user: by,
      verification_attempts: 0
    )
  end

  # Assigns without saving, so a caller that is already about to save (the firm
  # form) doesn't write the row twice.
  def reset_verification
    assign_attributes(
      verification_state: :unverified,
      verified_at: nil,
      verified_by_user: nil,
      verification_attempts: 0,
      last_code_sent_at: nil
    )
    self
  end

  def reset_verification!
    reset_verification
    save!
  end

  # Normalisation has to be callable without an instance: anything comparing a
  # typed-in value against a stored one must compare like with like, or
  # "98201 44210" looks like a change from "+919820144210" and needlessly
  # clears a verified badge.
  def self.normalise_value(kind:, value:)
    if kind.to_s == "email"
      value.to_s.downcase.strip.presence
    else
      Phone.normalise(value)
    end
  end

  private

  def normalise_value
    self.value = self.class.normalise_value(kind:, value:)
  end

  def value_matches_kind
    return if value.blank?

    case kind
    when "email"
      errors.add(:value, "is not a valid email address") unless value.match?(URI::MailTo::EMAIL_REGEXP)
    when "mobile", "whatsapp"
      errors.add(:value, "must be a valid mobile number") unless value.match?(/\A\+\d{10,15}\z/)
    end
  end
end
