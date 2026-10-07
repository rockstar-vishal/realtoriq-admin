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
  has_many :notifications, -> { unscope(where: :firm_id) }, dependent: :delete_all
  has_many :push_subscriptions, -> { unscope(where: :firm_id) }, dependent: :delete_all

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

  # Unscoped for the same reason as auth_sessions: the join key is not firm_id,
  # so FirmScoped's fail-closed `firm_id IS NULL` would hide every row.
  has_many :manager_links, -> { unscope(where: :firm_id) },
    class_name: "UserManager", foreign_key: :user_id, inverse_of: :user, dependent: :destroy
  has_many :managers, -> { unscope(where: :firm_id) },
    through: :manager_links, source: :manager

  has_many :report_links, -> { unscope(where: :firm_id) },
    class_name: "UserManager", foreign_key: :manager_id, inverse_of: :manager, dependent: :destroy
  has_many :direct_reports, -> { unscope(where: :firm_id) },
    through: :report_links, source: :user

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

  def can_manage_projects? = super_admin?

  # Self plus everyone who reports to this user, directly or through others.
  # One recursive query; calling this in a loop over users is the N+1 to avoid —
  # list endpoints should call it once for the current user.
  #
  # `across_firms` plus an explicit firm_id, so this does not depend on
  # Current.firm being set (console, cycle validation, services).
  def manageables
    ids = self.class.manageable_ids_for(self)
    self.class.across_firms.where(id: ids, firm_id: firm_id)
  end

  def assignable_users
    manageables.where(status: :active)
  end

  # Superadmin: every active user in the firm. Anyone else: active manageables,
  # which always includes themselves.
  def self.assignable_scope_for(actor)
    return none if actor.nil?

    actor.super_admin? ? actor.firm.users.where(status: :active) : actor.assignable_users
  end

  # Ids as strings so UUID comparisons against select_values stay consistent.
  # The CTE carries a path array so a cycle that slipped past validation cannot
  # loop the query; DISTINCT covers a person reachable down two managers.
  def self.manageable_ids_for(user)
    return [] if user&.id.blank? || user.firm_id.blank?

    sql = sanitize_sql_array([ <<~SQL.squish, id: user.id, firm_id: user.firm_id ])
      WITH RECURSIVE tree AS (
        SELECT id, ARRAY[id]::uuid[] AS path
        FROM users
        WHERE id = :id AND firm_id = :firm_id
        UNION ALL
        SELECT child.id, array_append(tree.path, child.id)
        FROM tree
        INNER JOIN user_managers
          ON user_managers.manager_id = tree.id
          AND user_managers.firm_id = :firm_id
        INNER JOIN users child
          ON child.id = user_managers.user_id
          AND child.firm_id = :firm_id
        WHERE NOT child.id = ANY (tree.path)
      )
      SELECT DISTINCT id FROM tree
    SQL

    connection.select_values(sql).map(&:to_s)
  end

  private

  def normalise_contact_details
    self.mobile = Phone.normalise(mobile)
    self.email = email.to_s.downcase.strip.presence
  end
end
