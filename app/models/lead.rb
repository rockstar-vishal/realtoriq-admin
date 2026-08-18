# frozen_string_literal: true

# A prospective buyer or tenant. The core CRM object.
class Lead < ApplicationRecord
  include FirmScoped

  TRANSACTION_TYPES = %w[sale rent].freeze
  # The design's tab strip carries "Missed f/u" alongside the real statuses,
  # but it is not one — it is next_action_at running late. Kept here so the
  # controller and the client agree on the spelling.
  DERIVED_STATUS_MISSED_FOLLOWUP = "missed_followup"

  enum :transaction_type, TRANSACTION_TYPES.index_by(&:itself), validate: true

  belongs_to :lead_status
  belongs_to :lead_source, optional: true
  belongs_to :property_type, optional: true

  # Unscoped, like every other association into a firm-scoped model reached
  # through an already-scoped parent (see User#auth_sessions). Reaching a lead
  # at all means the tenant check has happened, so its owner and its history are
  # necessarily in the same firm — while leaving them scoped makes them resolve
  # to nil or empty whenever Current.firm isn't set, silently.
  belongs_to :assigned_user, -> { unscope(where: :firm_id) },
    class_name: "User", optional: true

  has_many :lead_typologies, dependent: :destroy
  has_many :typologies, through: :lead_typologies
  # A booking requires a lead (NOT NULL), so the lead cannot outlive it. Declared
  # here rather than relying on Firm's association order, which would make firm
  # deletion depend on where a line happens to sit.
  has_many :bookings, -> { unscope(where: :firm_id) }, dependent: :destroy
  has_many :lead_activities, -> { unscope(where: :firm_id) }, dependent: :destroy
  # delete_all, not destroy: LeadStatusChange is readonly at the application
  # layer, and readonly blocks destroy as well as update — so instantiating
  # these to cascade would raise. A direct DELETE is also what we want, since
  # they have no dependents and no callbacks worth running.
  has_many :lead_status_changes, -> { unscope(where: :firm_id) }, dependent: :delete_all

  validates :mobile, presence: true, format: {
    with: /\A\+\d{10,15}\z/,
    message: "must be in international format, e.g. +919820144210"
  }
  validates :email, allow_blank: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :budget_min, :budget_max,
    numericality: { greater_than: 0, only_integer: true }, allow_nil: true
  validates :dead_reason, presence: true, if: -> { lead_status&.is_dead? }

  validate :budget_range_is_ordered
  validate :property_type_matches_transaction_type

  before_validation :normalise_contact_details
  before_validation :assign_code, on: :create

  # — visibility —
  #
  # Agents see only what is assigned to them; managers and the super admin see
  # the whole firm's pipeline. Unassigned leads are therefore invisible to
  # agents, which is why Leads::Create assigns an agent's own leads to them.
  scope :visible_to, ->(user) {
    user.super_admin? || user.manager? ? all : where(assigned_user_id: user.id)
  }

  # — filtering —
  scope :search, ->(term) {
    next all if term.blank?

    pattern = "%#{sanitize_sql_like(term.to_s.strip)}%"
    where("leads.name ILIKE :q OR leads.mobile ILIKE :q OR leads.email ILIKE :q", q: pattern)
  }

  scope :missed_followup, -> {
    joins(:lead_status)
      .where(lead_statuses: { is_terminal: false })
      .where(next_action_at: ...Time.current)
  }

  scope :with_status, ->(code) {
    next all if code.blank?
    next missed_followup if code == DERIVED_STATUS_MISSED_FOLLOWUP

    joins(:lead_status).where(lead_statuses: { code: })
  }

  # Overlap, not containment: a broker widening the budget filter expects to see
  # the lead whose range straddles the edge, not to have it hidden.
  scope :budget_between, ->(min, max) {
    scope = all
    scope = scope.where("leads.budget_max IS NULL OR leads.budget_max >= ?", min) if min.present?
    scope = scope.where("leads.budget_min IS NULL OR leads.budget_min <= ?", max) if max.present?
    scope
  }

  scope :possession_between, ->(from, to) {
    scope = all
    scope = scope.where(possession_by: from..) if from.present?
    scope = scope.where(possession_by: ..to) if to.present?
    scope
  }

  scope :for_typologies, ->(ids) {
    next all if ids.blank?

    where(id: LeadTypology.where(typology_id: ids).select(:lead_id)).distinct
  }

  # The list is a worklist, so what needs doing sorts to the top: overdue
  # followups first, then by when the next action is due, then newest.
  scope :as_worklist, -> {
    order(Arel.sql(<<~SQL.squish))
      CASE WHEN leads.next_action_at IS NOT NULL AND leads.next_action_at < NOW() THEN 0 ELSE 1 END,
      leads.next_action_at ASC NULLS LAST,
      leads.created_at DESC
    SQL
  }

  def overdue? = next_action_at.present? && next_action_at.past? && !lead_status.is_terminal?

  def visited? = first_visit_at.present?

  def display_name = name.presence || Phone.format_for_display(mobile)

  # Duplicates are allowed — the design's booking flow shows several leads on
  # one number — so this informs rather than blocks.
  def possible_duplicates
    return self.class.none if mobile.blank?

    self.class.where(mobile:).where.not(id:).order(created_at: :desc)
  end

  private

  def normalise_contact_details
    self.mobile = Phone.normalise(mobile)
    self.alt_mobile = Phone.normalise(alt_mobile) if alt_mobile.present?
    self.email = email.to_s.downcase.strip.presence
  end

  # Sequential per firm. Two concurrent creates can pick the same number, so the
  # unique index is the real guarantee and Leads::Create retries on collision.
  def assign_code
    return if code.present? || firm_id.blank?

    # Compare the numeric part, not the string: MAX('L-9999') beats MAX('L-10000')
    # lexically, so a string max would start reissuing codes at five digits.
    highest = self.class.unscoped.where(firm_id:).maximum(
      Arel.sql("NULLIF(regexp_replace(code, '\\D', '', 'g'), '')::bigint")
    ).to_i

    self.code = format("L-%04d", highest + 1)
  end

  def budget_range_is_ordered
    return if budget_min.blank? || budget_max.blank? || budget_max >= budget_min

    errors.add(:budget_max, "must be greater than or equal to the minimum budget")
  end

  # The design asks for a property type on sale leads and drops the question
  # entirely for rentals, so a rental carrying one means the client sent
  # something the user never chose.
  # Tests the association, not the foreign key: an unsaved property type is
  # present as an object while its id is still nil, and checking the id would
  # call that missing.
  def property_type_matches_transaction_type
    if sale? && property_type.blank?
      errors.add(:property_type_id, "is required for a sale lead")
    elsif rent? && property_type.present?
      errors.add(:property_type_id, "is not asked for a rental lead")
    end
  end
end
