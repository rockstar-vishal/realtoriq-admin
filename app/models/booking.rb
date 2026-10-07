# frozen_string_literal: true

# A sale and the brokerage earned on it.
class Booking < ApplicationRecord
  include FirmScoped

  STATUSES = %w[live cancelled].freeze

  enum :status, STATUSES.index_by(&:itself), validate: true

  # Unscoped for the reason documented on Lead: reached through a booking that
  # has already passed the tenant check.
  belongs_to :lead, -> { unscope(where: :firm_id) }
  belongs_to :project, -> { unscope(where: :firm_id) }, optional: true
  # project_id arrives straight from the client, so it needs checking — see
  # FirmScoped.belongs_to_same_firm. lead_id is resolved through the scoped
  # Lead in the controller, which is what makes it safe.
  belongs_to_same_firm :project
  belongs_to :created_by_user, -> { unscope(where: :firm_id) },
    class_name: "User", optional: true

  has_many :booking_documents, -> { unscope(where: :firm_id) }, dependent: :destroy
  # Collections before invoices: a collection points at an invoice, so the
  # invoice cannot go first.
  #
  # `destroy` rather than `restrict_with_error` because nothing in the app ever
  # destroys a booking — cancelling sets a status and keeps everything. The only
  # caller is a firm being deleted, and then the money records must go with it.
  has_many :collections, -> { unscope(where: :firm_id) }, dependent: :destroy
  has_many :invoices, -> { unscope(where: :firm_id) }, dependent: :destroy

  validates :booked_on, presence: true
  validates :agreement_value,
    numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :commission_percent,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validates :kicker, :passback,
    numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :client_paid_percent,
    numericality: { in: 0..100, only_integer: true }, allow_nil: true
  validates :cancellation_reason, presence: true, if: :cancelled?
  # Live bookings only: a cancelled row is history, including ones created
  # before unit_no was required. Re-validating it on cancel would 422 (and
  # Rails would serve public/422.html to a non-JSON Accept header).
  validates :unit_no, presence: true, if: -> { live? && project_id.present? }
  validates :unit_no, uniqueness: {
    scope: :project_id,
    conditions: -> { where(status: "live") },
    message: "is already booked on this project"
  }, if: -> { live? && project_id.present? && unit_no.present? }

  before_validation :normalise_unit_no
  before_validation :assign_code, on: :create
  # Recomputed on every save, so a corrected agreement value or commission can
  # never leave a stale figure behind.
  before_save :recompute_net_income

  # Cancelling "removes this booking from revenue" — every money query starts
  # from here.
  scope :live, -> { where(status: :live) }

  scope :search, ->(term) {
    next all if term.blank?

    pattern = "%#{sanitize_sql_like(term.to_s.strip)}%"
    left_joins(:project).where(
      "bookings.customer_name ILIKE :q OR bookings.unit_no ILIKE :q " \
      "OR bookings.builder_ref_no ILIKE :q OR bookings.code ILIKE :q " \
      "OR projects.name ILIKE :q", q: pattern
    )
  }

  scope :for_phone, ->(phone) {
    next all if phone.blank?

    where("bookings.customer_mobile ILIKE ?", "%#{sanitize_sql_like(Phone.normalise(phone).to_s.delete('+'))}%")
  }

  scope :booked_between, ->(from, to) {
    scope = all
    scope = scope.where(booked_on: from..) if from.present?
    scope = scope.where(booked_on: ..to) if to.present?
    scope
  }

  scope :recent_first, -> { order(booked_on: :desc, created_at: :desc) }

  # The design's formula, and its worked example: ₹1.56 Cr at 4.5% is ₹7.02 L,
  # plus a ₹50,000 kicker, minus a ₹66,000 passback, giving ₹6.86 L.
  #
  # BigDecimal throughout and rounded half-up exactly once, at the point the
  # commission meets the agreement value — never off an already-rounded figure.
  def self.calculate_net_income(agreement_value:, commission_percent:, kicker: 0, passback: 0)
    commission = (agreement_value.to_d * commission_percent.to_d / 100).round(0, :half_up)

    (commission + kicker.to_i - passback.to_i).to_i
  end

  def commission_amount
    (agreement_value.to_d * commission_percent.to_d / 100).round(0, :half_up).to_i
  end

  def invoiced_total = invoices.where(status: :raised).sum(:amount)

  def collected_total = collections.sum(:amount)

  def outstanding = invoiced_total - collected_total

  # What is still available to invoice. The hard block reads this.
  def invoiceable_balance = net_income - invoiced_total

  def registration_done? = registration_done_on.present?

  def cancel!(reason:, actor: nil)
    assign_attributes(status: :cancelled, cancelled_at: Time.current, cancellation_reason: reason)
    # Cancel is a status change. Staging still has live rows that would fail
    # today's validations (project set, unit_no blank). Those must still cancel.
    save!(validate: false)

    AuditEvent.record!(subject: self, firm:, actor:, action: "booking.cancelled",
                       metadata: { reason: })
    self
  end

  private

  def normalise_unit_no
    self.unit_no = unit_no.to_s.strip.presence
  end

  def recompute_net_income
    self.net_income = self.class.calculate_net_income(
      agreement_value:, commission_percent:, kicker:, passback:
    )
  end

  # Sequential per firm, like leads. The unique index is the real guarantee;
  # Bookings::Create retries on collision.
  def assign_code
    return if code.present? || firm_id.blank?

    highest = self.class.unscoped.where(firm_id:).maximum(
      Arel.sql("NULLIF(regexp_replace(code, '\\D', '', 'g'), '')::bigint")
    ).to_i

    self.code = format("B-%04d", highest + 1)
  end
end
