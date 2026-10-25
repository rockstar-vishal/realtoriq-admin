# frozen_string_literal: true

# A sale and the brokerage earned on it.
class Booking < ApplicationRecord
  include FirmScoped

  STATUSES = %w[live cancelled].freeze
  # Filter values, in the order the list pills show them. `#stage` checks
  # cancelled, then paid, then awaiting payment — a different order, because a
  # cancelled booking that has been paid is still cancelled.
  STAGES = %w[to_invoice awaiting_payment paid cancelled].freeze
  PAID_STAGE_SQL = "(bookings.net_income <= 0 OR bookings.collected_amount >= bookings.net_income)"
  AWAITING_STAGE_SQL = "(bookings.invoiced_amount > bookings.collected_amount)"

  enum :status, STATUSES.index_by(&:itself), validate: true

  LIVE_LISTING_INDEX = "index_bookings_on_live_firm_property"

  # Unscoped for the reason documented on Lead: reached through a booking that
  # has already passed the tenant check.
  belongs_to :lead, -> { unscope(where: :firm_id) }
  belongs_to :project, -> { unscope(where: :firm_id) }, optional: true
  # Another firm's marketplace listing stays readable after it leaves the
  # marketplace. Not belongs_to_same_firm: the visible set is wider than the
  # tenant, and link_problem is what refuses the rest.
  belongs_to :property, -> { unscope(where: :firm_id) }, optional: true
  # project_id arrives straight from the client, so it needs checking — see
  # FirmScoped.belongs_to_same_firm. lead_id is resolved through the scoped
  # Lead in the controller, which is what makes it safe.
  belongs_to_same_firm :project
  # The configuration row on the project, when it still exists. A project save
  # replaces those rows and nulls this pointer. typology_id and
  # configuration_label are what was booked, and they stay. The id is
  # client-supplied, so it has to be this project's row — ProjectTypology has
  # no firm_id for belongs_to_same_firm.
  belongs_to :project_typology, optional: true
  belongs_to :typology, optional: true
  # Set by the bookings controller when the request sends project_typology_id
  # as null. Leaving the key out must not clear the snapshot: the pointer can
  # already be null because the project replaced its configurations.
  attr_accessor :clear_booked_configuration
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
  validate :configuration_belongs_to_the_project
  validate :copy_link_problem_onto_errors

  before_validation :normalise_unit_no
  before_validation :remember_configuration
  before_validation :assign_code, on: :create
  # Recomputed on every save, so a corrected agreement value or commission can
  # never leave a stale figure behind.
  before_save :recompute_net_income

  # Cancelling "removes this booking from revenue" — every money query starts
  # from here.
  scope :live, -> { where(status: :live) }

  # Four or more digits also match the stored phone with the punctuation
  # stripped, the way a lead's mobile search does. "98201 55011" is not a
  # substring of "+919820155011".
  scope :search, ->(term) {
    next all if term.blank?

    raw = term.to_s.strip
    pattern = "%#{sanitize_sql_like(raw)}%"
    clauses = [
      "bookings.customer_name ILIKE :q",
      "bookings.customer_mobile ILIKE :q",
      "bookings.unit_no ILIKE :q",
      "bookings.builder_ref_no ILIKE :q",
      "bookings.code ILIKE :q",
      "projects.name ILIKE :q"
    ]
    binds = { q: pattern }
    digits = raw.gsub(/\D/, "")
    if digits.length >= 4
      clauses << "bookings.customer_mobile LIKE :digits"
      binds[:digits] = "%#{sanitize_sql_like(digits)}%"
    end
    left_joins(:project).where(clauses.join(" OR "), binds)
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

  scope :with_registration, ->(value) {
    case value.to_s
    when "done" then where.not(registration_done_on: nil)
    when "pending" then where(registration_done_on: nil)
    else all
    end
  }

  # Same order as `#stage`. `paid` is only live rows: a cancelled booking that
  # has been collected stays cancelled, and must not also match `paid`.
  scope :in_stage, ->(stage) {
    case stage.to_s
    when "cancelled" then where(status: "cancelled")
    when "paid" then live.where(PAID_STAGE_SQL)
    when "awaiting_payment" then live.where("NOT #{PAID_STAGE_SQL}").where(AWAITING_STAGE_SQL)
    when "to_invoice" then live.where("NOT #{PAID_STAGE_SQL}").where("NOT #{AWAITING_STAGE_SQL}")
    else none
    end
  }

  def self.money_totals(scope)
    agreement, net, invoiced, collected, to_invoice = aggregate_row(scope.live, MONEY_TOTALS_SQL)
    {
      agreement_value: agreement,
      net_income: net,
      invoiced:,
      collected:,
      outstanding: invoiced - collected,
      to_invoice:
    }
  end

  def self.stage_counts(scope)
    all, to_invoice, awaiting_payment, paid, cancelled = aggregate_row(scope, STAGE_COUNT_SQL)
    { all:, to_invoice:, awaiting_payment:, paid:, cancelled: }
  end

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

  # Stored totals. The list, the stage and the balance the client sees read
  # these. RaiseInvoice and RecordCollection recompute them in the same
  # transaction as the write; the over-invoice and over-collect locks do not
  # trust them and read `#live_invoiced_sum` / `#live_collected_sum` instead.
  def invoiced_total = invoiced_amount.to_i

  def collected_total = collected_amount.to_i

  def outstanding = invoiced_total - collected_total

  def invoiceable_balance = net_income.to_i - invoiced_total

  def to_invoice_amount = [ invoiceable_balance, 0 ].max

  def stage
    return "cancelled" if cancelled?
    return "paid" if net_income.to_i <= 0 || collected_amount.to_i >= net_income.to_i
    return "awaiting_payment" if invoiced_amount.to_i > collected_amount.to_i

    "to_invoice"
  end

  # The issue date of the oldest raised invoice that still has a balance of
  # its own. An unlinked collection does not settle an invoice.
  def oldest_due_invoice_on
    paid_toward = collections.to_a.each_with_object(Hash.new(0)) do |row, sums|
      next if row.invoice_id.blank?

      sums[row.invoice_id] += row.amount.to_i
    end
    due = invoices.to_a.select { |invoice| invoice.raised? && invoice.amount.to_i > paid_toward[invoice.id] }
    due.min_by { |invoice| [ invoice.issued_on, invoice.created_at, invoice.id ] }&.issued_on
  end

  def live_invoiced_sum
    Invoice.unscoped.where(booking_id: id, status: "raised").sum(:amount).to_i
  end

  def live_collected_sum
    Collection.unscoped.where(booking_id: id).sum(:amount).to_i
  end

  def refresh_money!
    update_columns(
      invoiced_amount: live_invoiced_sum,
      collected_amount: live_collected_sum,
      updated_at: Time.current
    )
  end

  def registration_done? = registration_done_on.present?

  # The project's current row for this snapshot, so the edit form can preselect
  # it after the old row has been replaced. The pointer wins while it lives.
  def configuration_choice_id
    return project_typology_id if project_typology_id.present?
    return if typology_id.blank? || project.nil?

    wanted = configuration_label.to_s.downcase
    project.project_typologies.detect do |row|
      row.typology_id == typology_id && row.label.to_s.downcase == wanted
    end&.id
  end

  def configuration_display_name
    ProjectTypology.new(label: configuration_label, typology:).display_name
  end

  def cancel!(reason:, actor: nil, release_property: false)
    transaction do
      assign_attributes(status: :cancelled, cancelled_at: Time.current, cancellation_reason: reason)
      # Cancel is a status change. Staging still has live rows that would fail
      # today's validations (project set, unit_no blank). Those must still cancel.
      save!(validate: false)

      AuditEvent.record!(subject: self, firm:, actor:, action: "booking.cancelled",
                         metadata: { reason: })
      Bookings::ListingStatus.release!(self, actor) if ActiveModel::Type::Boolean.new.cast(release_property)
    end
    self
  end

  # What the API returns before it saves. Nil when the link is fine. A listing
  # that was bookable and later left the marketplace stays linked: the check
  # runs only when property_id is being set.
  def link_problem
    if project_id.present? && property_id.present?
      return { code: "project_and_listing", message: "A booking is on a project or a listing, not both." }
    end

    if property_id.present? && (new_record? || will_save_change_to_property_id?)
      listing = Property.unscoped.find_by(id: property_id)
      unless self.class.listing_bookable?(firm, listing)
        return { code: "listing_not_found", message: "That listing could not be found." }
      end
    end

    other = conflicting_live_listing
    if other
      return {
        code: "listing_already_booked",
        message: "This listing already has a live booking.",
        details: { booking_id: other.id, code: other.code }
      }
    end

    nil
  end

  # Own listings of any status. A marketplace listing uses the same firm rule
  # as a shared property, without requiring it to still be Available.
  def self.listing_bookable?(firm, listing)
    return false if firm.nil? || listing.nil?
    return true if listing.firm_id == firm.id
    return false unless listing.listed_on_marketplace?
    return false if firm.review_demo?

    Firm.marketplace_eligible.exists?(id: listing.firm_id)
  end

  # Another live booking of this firm on the same listing. This row is
  # excluded, including after it has just been cancelled.
  def other_live_listing_booking
    return if property_id.blank?

    scope = self.class.unscoped.where(firm_id:, property_id:, status: "live")
    scope = scope.where.not(id:) if id.present?
    scope.first
  end

  def conflicting_live_listing
    return unless live?

    other_live_listing_booking
  end

  # Re-select by id so a search join cannot make SUM or COUNT see one booking
  # twice. `includes` is dropped with the order: summing a scope that has
  # loaded invoices counts the booking once per invoice.
  def self.aggregate_row(scope, expressions)
    ids = scope.unscope(:order).reselect(arel_table[:id])
    row = where(id: ids).pick(*expressions.map { |sql| Arel.sql(sql) })
    numbers = Array(row).map { |value| value.to_i }
    numbers = Array.new(expressions.size, 0) if numbers.size < expressions.size
    numbers
  end
  private_class_method :aggregate_row

  MONEY_TOTALS_SQL = [
    "COALESCE(SUM(bookings.agreement_value), 0)",
    "COALESCE(SUM(bookings.net_income), 0)",
    "COALESCE(SUM(bookings.invoiced_amount), 0)",
    "COALESCE(SUM(bookings.collected_amount), 0)",
    "COALESCE(SUM(GREATEST(bookings.net_income - bookings.invoiced_amount, 0)), 0)"
  ].freeze

  STAGE_COUNT_SQL = [
    "COUNT(*) FILTER (WHERE bookings.status = 'live')",
    "COUNT(*) FILTER (WHERE bookings.status = 'live' AND NOT #{PAID_STAGE_SQL} AND NOT #{AWAITING_STAGE_SQL})",
    "COUNT(*) FILTER (WHERE bookings.status = 'live' AND NOT #{PAID_STAGE_SQL} AND #{AWAITING_STAGE_SQL})",
    "COUNT(*) FILTER (WHERE bookings.status = 'live' AND #{PAID_STAGE_SQL})",
    "COUNT(*) FILTER (WHERE bookings.status = 'cancelled')"
  ].freeze

  private

  def normalise_unit_no
    self.unit_no = unit_no.to_s.strip.presence
  end

  def remember_configuration
    if property_id.present?
      self.project_typology_id = nil
      return unless new_record? || will_save_change_to_property_id?

      listing = Property.unscoped.find_by(id: property_id)
      self.typology_id = listing&.typology_id
      self.configuration_label = nil
      return
    end

    if project_id.blank? || clear_booked_configuration
      self.project_typology_id = nil
      self.typology_id = nil
      self.configuration_label = nil
      return
    end

    return if project_typology_id.blank?

    row = project_typology
    return unless row&.project_id == project_id

    self.typology_id = row.typology_id
    self.configuration_label = row.label
  end

  def copy_link_problem_onto_errors
    problem = link_problem
    return if problem.nil?

    case problem[:code]
    when "project_and_listing"
      errors.add(:base, :project_and_listing, message: problem[:message])
    when "listing_not_found"
      errors.add(:property_id, :listing_not_found, message: problem[:message])
    when "listing_already_booked"
      errors.add(:property_id, :listing_already_booked, message: problem[:message])
    end
  end

  def configuration_belongs_to_the_project
    return if project_typology_id.blank?
    return if project_typology&.project_id == project_id

    errors.add(:project_typology_id, "isn't a configuration of this project")
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
