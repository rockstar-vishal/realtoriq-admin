# frozen_string_literal: true

# One Facebook login for a firm. At most one row is active. Disconnect keeps
# the row and clears the token, so the next Connect can reuse the pages.
class FacebookConnection < ApplicationRecord
  include FirmScoped

  TOKEN_KINDS = %w[user_access system_access].freeze
  STATUSES = %w[active invalid disconnected].freeze

  enum :token_kind, TOKEN_KINDS.index_by(&:itself), validate: true, default: :user_access
  enum :status, STATUSES.index_by(&:itself), prefix: :connection, validate: true, default: :active

  encrypts :access_token

  belongs_to :connected_by_user, -> { unscope(where: :firm_id) }, class_name: "User"
  belongs_to_same_firm :connected_by_user
  has_many :facebook_pages, -> { unscope(where: :firm_id) }, dependent: :destroy

  validates :fb_user_id, presence: true

  scope :active_connections, -> { where(status: "active") }

  # The connection the firm is still using. Invalid counts: that is the
  # reconnect path, and its Pages must stay visible.
  def self.current_for(firm)
    return if firm.nil?

    across_firms.where(firm_id: firm.id, status: %w[active invalid])
      .order(created_at: :desc, id: :desc).first
  end

  def superadmin_recipients
    User.across_firms.where(firm_id:, role: "super_admin", status: "active")
  end

  # Nil means the token never expires. Used for the 7-day warning only.
  def token_expiring_soon?
    token_expires_at.present? && token_expires_at < 7.days.from_now
  end

  def mark_active!
    update!(status: :active, error_code: nil, error_details: {}, last_health_check_at: Time.current)
  end

  # True only for the worker that moved active → invalid. A second caller
  # must not send another alert.
  def claim_invalid!(error_code: nil, message: nil)
    now = Time.current
    claimed = self.class.across_firms.where(id:, status: "active").update_all(
      status: "invalid",
      error_code: error_code.to_s.presence,
      updated_at: now
    )
    return false unless claimed == 1

    self.class.across_firms.where(id:).update_all(
      error_details: { "message" => message, "timestamp" => now.iso8601 }.compact
    )
    reload
    true
  end
end
