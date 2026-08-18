# frozen_string_literal: true

# The tenant: a brokerage / channel-partner firm.
#
# Firm itself is not FirmScoped — it *is* the scope. Everything that hangs off
# it is.
class Firm < ApplicationRecord
  STATUSES = %w[pending active suspended churned].freeze

  enum :status, STATUSES.index_by(&:itself), validate: true

  belongs_to :city, optional: true
  belongs_to :locality, optional: true

  has_many :users, dependent: :destroy
  has_many :contact_channels, dependent: :destroy
  has_many :firm_bank_accounts, dependent: :destroy
  has_many :leads, dependent: :destroy
  has_many :bookings, dependent: :destroy
  has_many :projects, dependent: :destroy
  # Properties before buildings: a building refuses to go while it still holds
  # listings, and dependent order is declaration order.
  has_many :properties, dependent: :destroy
  has_many :buildings, dependent: :destroy
  # Builders a broker added inline. The platform's global list has no firm and
  # is untouched by this.
  has_many :builders, dependent: :destroy
  # Same reasoning as Lead#lead_status_changes — AuditEvent is readonly, and
  # readonly blocks destroy too.
  has_many :audit_events, dependent: :delete_all
  has_many :subscriptions, dependent: :destroy

  has_one :super_admin, -> { where(role: :super_admin) }, class_name: "User", inverse_of: :firm
  has_one :primary_bank_account, -> { where(primary: true) },
    class_name: "FirmBankAccount", inverse_of: :firm

  has_one :current_subscription, -> { live.order(current_period_start: :desc) },
    class_name: "Subscription", inverse_of: :firm

  has_one_attached :logo do |attachable|
    attachable.variant :thumb, resize_to_limit: [ 96, 96 ], preprocessed: true
  end

  validates :name, presence: true, length: { maximum: 160 }
  validates :slug, presence: true, uniqueness: { case_sensitive: false },
    format: { with: /\A[a-z0-9\-]+\z/, message: "may only contain lowercase letters, numbers and hyphens" }
  validates :code, presence: true, uniqueness: { case_sensitive: false }
  validates :pincode, format: { with: /\A\d{6}\z/ }, allow_blank: true
  validates :pan, format: { with: /\A[A-Z]{5}\d{4}[A-Z]\z/, message: "is not a valid PAN" }, allow_blank: true
  validates :suspension_reason, presence: true, if: :suspended?

  validate :logo_is_a_reasonable_image

  before_validation :normalise_identifiers
  before_validation :assign_slug, on: :create
  before_validation :assign_code, on: :create

  # An EXISTS subquery rather than a join onto :users. A join would inherit
  # User's FirmScoped default scope and match nothing whenever the caller
  # hasn't set a tenant — which is exactly the admin panel's situation. Raw SQL
  # here sidesteps that entirely, and skips the DISTINCT a join would need.
  scope :search, ->(term) {
    next all if term.blank?

    pattern = "%#{sanitize_sql_like(term.to_s.strip)}%"

    where(
      "firms.name ILIKE :q OR firms.legal_name ILIKE :q OR firms.code ILIKE :q OR EXISTS (" \
      "  SELECT 1 FROM users" \
      "  WHERE users.firm_id = firms.id AND (users.mobile ILIKE :q OR users.email ILIKE :q)" \
      ")",
      q: pattern
    )
  }

  def to_param = slug

  def display_name = name.presence || legal_name

  # How many devices one user may stay signed in on. Comes from the plan;
  # a firm with no live subscription still gets a floor so support can get in.
  def device_limit = current_subscription&.plan&.max_devices || 2

  # A firm counts as verified only when all three channels are. The admin index
  # shows the three individually, but gates and filters use this.
  def fully_verified?
    ContactChannel::KINDS.all? { |kind| contact_channels.any? { |c| c.kind == kind && c.verified? } }
  end

  def activate!(actor: nil)
    transaction do
      update!(status: :active, activated_at: Time.current, suspended_at: nil, suspension_reason: nil)
      AuditEvent.record!(actor:, subject: self, action: "firm.activated")
    end
  end

  def suspend!(reason:, actor: nil)
    transaction do
      update!(status: :suspended, suspended_at: Time.current, suspension_reason: reason)
      AuditEvent.record!(actor:, subject: self, action: "firm.suspended", metadata: { reason: })
    end
  end

  private

  def normalise_identifiers
    self.slug = slug.to_s.downcase.strip.presence
    self.code = code.to_s.upcase.strip.presence
    self.pan = pan.to_s.upcase.strip.presence
    self.gst_number = gst_number.to_s.upcase.strip.presence
  end

  def assign_slug
    return if slug.present?

    base = name.to_s.parameterize.presence || "firm"
    self.slug = uniquify(base) { |candidate| self.class.exists?(slug: candidate) }
  end

  # CP-MH-04218 in the design: a fixed prefix, the state the firm operates in,
  # and a five-digit serial. Random rather than sequential so the code doesn't
  # leak how many firms are on the platform.
  def assign_code
    return if code.present?

    region = city&.state_code.presence || "IN"

    found = 12.times do
      candidate = format("CP-%s-%05d", region, SecureRandom.random_number(100_000))
      break candidate unless self.class.exists?(code: candidate)
    end

    # Integer#times returns the count when no break fires — twelve collisions in
    # a 100k space means the space is genuinely crowded, so widen it rather than
    # looping forever.
    self.code = found.is_a?(String) ? found : "CP-#{region}-#{SecureRandom.alphanumeric(6).upcase}"
  end

  def uniquify(base)
    return base unless yield(base)

    2.upto(50) do |n|
      candidate = "#{base}-#{n}"
      return candidate unless yield(candidate)
    end

    "#{base}-#{SecureRandom.alphanumeric(6).downcase}"
  end

  def logo_is_a_reasonable_image
    return unless logo.attached?

    unless logo.blob.content_type.in?(%w[image/png image/jpeg image/svg+xml image/webp])
      errors.add(:logo, "must be a PNG, JPG, SVG or WebP")
    end

    errors.add(:logo, "must be smaller than 1 MB") if logo.blob.byte_size > 1.megabyte
  end
end
