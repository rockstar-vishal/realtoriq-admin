# frozen_string_literal: true

# One row on a firm's calling list. Not a lead: there is no budget, no
# pipeline, and a manager may hard-delete it. The lead created when the
# caller is interested is a normal lead and is deleted only by
# Prospects::MoveToFollowing, and only while that lead has not been worked.
class Prospect < ApplicationRecord
  include FirmScoped

  STATUSES = %w[new following interested not_interested].freeze
  MAX_PER_FIRM = 5_000
  NAME_MAX = 200
  COMMENT_MAX = 2_000
  MOBILE_FORMAT = /\A\+91[6-9]\d{9}\z/

  # `prefix` because a value named "new" would override Active Record's `new`.
  enum :status, STATUSES.index_by(&:itself), prefix: :status, validate: true

  # Unscoped: a marketplace project has no firm, and FirmScoped would read it
  # back as nil. belongs_to_same_firm is what keeps a client-supplied id honest.
  belongs_to :project, -> { unscope(where: :firm_id) }, optional: true
  belongs_to :property, -> { unscope(where: :firm_id) }, optional: true
  belongs_to :lead, -> { unscope(where: :firm_id) }, optional: true
  belongs_to :created_by, -> { unscope(where: :firm_id) },
    class_name: "User", optional: true

  belongs_to_same_firm :project, allow_marketplace: true
  belongs_to_same_firm :property
  belongs_to_same_firm :lead
  belongs_to_same_firm :created_by

  has_many :prospect_followups, -> { unscope(where: :firm_id) }, dependent: :delete_all

  validates :mobile, presence: true, format: { with: MOBILE_FORMAT, message: "must be an Indian mobile number" }
  validates :name, length: { maximum: NAME_MAX }, allow_blank: true
  validates :comment, length: { maximum: COMMENT_MAX }, allow_blank: true
  validate :one_inventory_link
  validate :within_firm_cap, on: :create

  # The importer counts under the firm lock and sets this so each inserted row
  # does not COUNT the firm again. Other creates still enforce the cap.
  attr_accessor :firm_cap_reserved

  scope :search, ->(term) { Search.apply(self, term) }

  # Still to call. The opening list sends view=worklist.
  scope :worklist, -> { where(status: %w[new following]) }

  # Comma list or repeated param. Unknown values are ignored. An empty
  # known list leaves the scope alone.
  scope :with_status, ->(value) {
    codes = Array(value).flat_map { |item| item.to_s.split(",") }.map(&:strip)
    codes = codes.select { |code| STATUSES.include?(code) }.uniq
    next all if codes.empty?

    where(status: codes)
  }

  scope :named_like, ->(term) {
    raw = term.to_s.strip
    next all if raw.blank?

    where("prospects.name ILIKE ?", "%#{sanitize_sql_like(raw)}%")
  }

  # Same cleaning as search. Fewer than 4 digits does not filter.
  scope :mobile_like, ->(term) {
    digits = Search.phone_digits(term.to_s)
    next all if digits.length < 4

    where(
      "regexp_replace(prospects.mobile, '\\D', '', 'g') LIKE ?",
      "%#{sanitize_sql_like(digits)}%"
    )
  }

  # Overdue dial time on a prospect still on the list. Not a status.
  scope :missed_followup, -> {
    where(next_action_at: ..Time.current, status: %w[new following])
  }

  scope :with_missed_followup, ->(flag) {
    next all if flag.nil? || flag.to_s.strip == ""

    if ActiveModel::Type::Boolean.new.cast(flag)
      missed_followup
    else
      where.not(id: missed_followup.select(:id))
    end
  }

  # Inclusive IST calendar days, the same bounds as Lead.ncd_between.
  scope :ncd_between, ->(from, to) {
    zone = Time.find_zone(Lead::NCD_ZONE)
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

  scope :created_between, ->(from, upto) {
    range = Reports::Window.time_range(from, upto)
    next all if range.nil?

    where(created_at: range)
  }

  scope :as_ncd, -> {
    order(Arel.sql("prospects.next_action_at ASC NULLS FIRST, prospects.created_at DESC, prospects.id ASC"))
  }

  scope :as_updated, -> { order(updated_at: :desc, id: :desc) }

  def self.counts
    zone = Time.find_zone(Lead::NCD_ZONE)
    now = Time.current
    day = now.in_time_zone(zone)
    sql = sanitize_sql_array([
      <<~SQL.squish,
        COUNT(*) FILTER (WHERE status = 'new'),
        COUNT(*) FILTER (WHERE status = 'following'),
        COUNT(*) FILTER (WHERE status = 'interested'),
        COUNT(*) FILTER (WHERE status = 'not_interested'),
        COUNT(*),
        COUNT(*) FILTER (WHERE status IN ('new', 'following')),
        COUNT(*) FILTER (WHERE next_action_at BETWEEN :day_start AND :day_end),
        COUNT(*) FILTER (WHERE next_action_at <= :now AND status IN ('new', 'following'))
      SQL
      { now:, day_start: day.beginning_of_day, day_end: day.end_of_day }
    ])
    new_count, following, interested, not_interested, total,
      worklist, todays_followups, missed_followup = pick(Arel.sql(sql))

    {
      new: new_count.to_i,
      following: following.to_i,
      interested: interested.to_i,
      not_interested: not_interested.to_i,
      total: total.to_i,
      worklist: worklist.to_i,
      todays_followups: todays_followups.to_i,
      missed_followup: missed_followup.to_i
    }
  end

  # One query for the page, not every note on every card. `id::text` matches
  # the string comparison used when the association is already loaded.
  def self.preload_latest_notes(prospects)
    list = Array(prospects)
    notes = ProspectFollowup.latest_notes_for(list.filter_map(&:id))
    list.each do |prospect|
      prospect.instance_variable_set(:@latest_note_ready, true)
      prospect.instance_variable_set(:@latest_note, notes[prospect.id])
    end
  end

  def latest_note
    return @latest_note if @latest_note_ready

    rows = prospect_followups
    latest = if rows.loaded?
      rows.max_by { |row| [ row.created_at, row.id.to_s ] }
    else
      rows.order(created_at: :desc, id: :desc).first
    end
    latest&.notes
  end

  # Not interested can be reopened by anyone. Interested can be sent back only
  # by someone who could open the lead, because that path deletes the lead.
  def can_move_to_following?(user)
    return true if status_not_interested?
    return false unless status_interested?

    user.super_admin? || user.manager? || lead&.assigned_user_id == user.id
  end

  def manager_can_delete?(user)
    user.super_admin? || user.manager?
  end

  private

  def one_inventory_link
    return if project_id.blank? || property_id.blank?

    errors.add(:base, "A prospect can have a project or a property, not both")
  end

  def within_firm_cap
    return if firm_id.blank? || firm_cap_reserved
    return if self.class.unscoped.where(firm_id:).where.not(id:).count < MAX_PER_FIRM

    errors.add(:base, "Your firm already has #{MAX_PER_FIRM} prospects.")
  end

  # Name, phone digits, or status. A one- or two-digit phone fragment is
  # ignored so "91" does not match every row.
  module Search
    module_function

    def apply(scope, term)
      raw = term.to_s.strip
      return scope if raw.blank?

      pattern = "%#{Prospect.sanitize_sql_like(raw)}%"
      status_pattern = "%#{Prospect.sanitize_sql_like(raw.downcase.gsub(/\s+/, "_"))}%"
      clauses = [ "prospects.name ILIKE :q", "prospects.status ILIKE :status_q" ]
      binds = { q: pattern, status_q: status_pattern }

      digits = phone_digits(raw)
      if digits.length >= 4
        clauses << "regexp_replace(prospects.mobile, '\\D', '', 'g') LIKE :digits"
        binds[:digits] = "%#{Prospect.sanitize_sql_like(digits)}%"
      end

      scope.where(clauses.join(" OR "), binds)
    end

    def phone_digits(raw)
      digits = raw.gsub(/\D/, "").sub(/\A0+/, "")
      digits = digits.sub(/\A91/, "") if digits.length > 10 && digits.start_with?("91")
      digits
    end
  end
end
