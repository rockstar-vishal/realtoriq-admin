# frozen_string_literal: true

# A prospective buyer or tenant. The core CRM object.
class Lead < ApplicationRecord
  include FirmScoped

  TRANSACTION_TYPES = %w[sale rent].freeze
  # The design's tab strip carries "Missed f/u" alongside the real statuses,
  # but it is not one — it is next_action_at running late. Kept here so the
  # controller and the client agree on the spelling.
  DERIVED_STATUS_MISSED_FOLLOWUP = "missed_followup"
  # Convenience for the Hot / Negotiation card. Same as status[]=hot&status[]=negotiation.
  DERIVED_STATUS_HOT_NEGOTIATION = "hot_negotiation"
  HOT_NEGOTIATION_CODES = %w[hot negotiation].freeze
  NCD_ZONE = "Asia/Kolkata"

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
  # Create and PATCH both resolve assigned_user_id through User.assignable_scope_for.
  # This covers console / future write paths that skip that resolver.
  belongs_to_same_firm :assigned_user

  has_many :lead_typologies, dependent: :destroy
  has_many :typologies, through: :lead_typologies
  has_many :lead_projects, -> { unscope(where: :firm_id) }, dependent: :destroy
  has_many :lead_properties, -> { unscope(where: :firm_id) }, dependent: :destroy
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
  validate :mobile_unique_per_transaction_type

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
    codes = Array(code).flatten.map { |value| value.to_s.strip }.compact_blank
    next all if codes.empty?

    missed = codes.delete(DERIVED_STATUS_MISSED_FOLLOWUP)
    codes.concat(HOT_NEGOTIATION_CODES) if codes.delete(DERIVED_STATUS_HOT_NEGOTIATION)
    codes.uniq!

    next missed_followup if missed && codes.empty?

    joins(:lead_status).where(lead_statuses: { code: codes })
  }

  # A single stored amount (budget_max, falling back to leftover budget_min)
  # inside the filter window. Query params keep the names budget_min / budget_max
  # because that is the window, not a range overlap on the lead.
  scope :budget_between, ->(min, max) {
    next all if min.blank? && max.blank?

    amount = "COALESCE(leads.budget_max, leads.budget_min)"
    scope = all
    scope = scope.where("#{amount} >= ?", min) if min.present?
    scope = scope.where("#{amount} <= ?", max) if max.present?
    scope
  }

  scope :named_like, ->(term) {
    next all if term.blank?

    pattern = "%#{sanitize_sql_like(term.to_s.strip)}%"
    where("leads.name ILIKE ?", pattern)
  }

  scope :email_like, ->(term) {
    next all if term.blank?

    pattern = "%#{sanitize_sql_like(term.to_s.strip)}%"
    where("leads.email ILIKE ?", pattern)
  }

  # Digits only, so "98201 44210" matches the stored E.164 +919820144210.
  scope :mobile_like, ->(term) {
    next all if term.blank?

    digits = term.to_s.gsub(/\D/, "")
    next all if digits.blank?

    where("leads.mobile LIKE ?", "%#{sanitize_sql_like(digits)}%")
  }

  scope :with_visited, ->(flag) {
    next all if flag.nil? || flag.to_s.strip == ""

    if ActiveModel::Type::Boolean.new.cast(flag)
      where.not(first_visit_at: nil)
    else
      where(first_visit_at: nil)
    end
  }

  # Inclusive IST calendar days: ncd_from at 00:00 through ncd_upto at 23:59:59.
  scope :ncd_between, ->(from, to) {
    zone = Time.find_zone(NCD_ZONE)
    scope = all
    if from.present?
      start_at = zone.parse(from.to_s)&.beginning_of_day
      scope = scope.where(next_action_at: start_at..) if start_at
    end
    if to.present?
      end_at = zone.parse(to.to_s)&.end_of_day
      scope = scope.where(next_action_at: ..end_at) if end_at
    end
    scope
  }

  scope :possession_between, ->(from, to) {
    scope = all
    scope = scope.where(possession_by: from..) if from.present?
    scope = scope.where(possession_by: ..to) if to.present?
    scope
  }

  # No `.distinct`: the subquery filters on the primary key, so a lead can match
  # at most once and it was never needed. It was also actively harmful — combined
  # with `as_worklist`, Postgres rejects the query ("for SELECT DISTINCT, ORDER BY
  # expressions must appear in select list"), so this documented filter returned
  # a 500 on the default sort and worked on every other one.
  scope :for_typologies, ->(ids) {
    next all if ids.blank?

    where(id: LeadTypology.where(typology_id: ids).select(:lead_id))
  }

  # Default GET /leads: next action soonest, with no date at all sitting above
  # overdue — a new lead with nothing scheduled is the thing to pick up first.
  scope :as_ncd, -> {
    order(Arel.sql("leads.next_action_at ASC NULLS FIRST, leads.created_at DESC"))
  }

  # GET /leads?sort=worklist: overdue followups first, then by when the next
  # action is due, then newest. The home strip no longer uses this — it is
  # missed followups only.
  scope :as_worklist, -> {
    order(Arel.sql(<<~SQL.squish))
      CASE WHEN leads.next_action_at IS NOT NULL AND leads.next_action_at < NOW() THEN 0 ELSE 1 END,
      leads.next_action_at ASC NULLS LAST,
      leads.created_at DESC
    SQL
  }

  def overdue? = next_action_at.present? && next_action_at.past? && !lead_status.is_terminal?

  def visited? = first_visit_at.present?

  # List-card extras. `visit_count` is logged site visits, not the `visited`
  # badge. `last_followup_comment` is the latest loggable activity body — not
  # `next_action_note` (that is the planned next action).
  def visit_count
    return @visit_count if defined?(@visit_count)

    @visit_count = lead_activities.visit.count
  end

  def last_followup_comment
    return @last_followup_comment if defined?(@last_followup_comment)

    @last_followup_comment = lead_activities
      .where(kind: LeadActivity::LOGGABLE_KINDS)
      .recent_first
      .pick(:body)
  end

  def assign_card_extras(visit_count:, last_followup_comment:)
    @visit_count = visit_count
    @last_followup_comment = last_followup_comment
    self
  end

  # Two queries for a page of leads, so the list card does not N+1.
  def self.preload_card_extras(leads)
    records = Array(leads)
    ids = records.map(&:id)
    return records if ids.empty?

    visit_counts = LeadActivity.where(lead_id: ids, kind: "visit").group(:lead_id).count
    comments = LeadActivity
      .where(lead_id: ids, kind: LeadActivity::LOGGABLE_KINDS)
      .select("DISTINCT ON (lead_activities.lead_id) lead_activities.lead_id, lead_activities.body")
      .order(Arel.sql("lead_activities.lead_id, lead_activities.occurred_at DESC, lead_activities.created_at DESC"))
      .each_with_object({}) { |row, hash| hash[row.lead_id] = row.body }

    records.each do |lead|
      lead.assign_card_extras(
        visit_count: visit_counts.fetch(lead.id, 0),
        last_followup_comment: comments[lead.id]
      )
    end
  end

  # Display / filter amount. Writes store only budget_max; leftover rows may
  # still have a min and a null max.
  def budget_amount = budget_max.presence || budget_min

  def display_name = name.presence || Phone.format_for_display(mobile)

  # Same number, the other transaction type — sale and rent may coexist. Same
  # type is refused (see #duplicate_on_mobile_and_type); this is informational.
  def possible_duplicates
    return self.class.none if mobile.blank?

    self.class.where(mobile:).where.not(id:).order(created_at: :desc)
  end

  # The other lead that occupies (firm, mobile, transaction_type), if any.
  def duplicate_on_mobile_and_type
    return if mobile.blank? || transaction_type.blank? || firm_id.blank?

    self.class.unscoped.where(firm_id:, mobile:, transaction_type:).where.not(id:).first
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

  def mobile_unique_per_transaction_type
    return if duplicate_on_mobile_and_type.nil?

    errors.add(:mobile, "already has a #{transaction_type} lead")
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
