# frozen_string_literal: true

# A firm's billing state. Ops-managed: nobody charges a card here, so `status`
# is whatever ops last set, plus an expiry that the app can enforce on its own.
class Subscription < ApplicationRecord
  include FirmScoped

  STATUSES = %w[trialing active past_due lapsed cancelled].freeze
  LIVE_STATUSES = %w[trialing active].freeze

  enum :status, STATUSES.index_by(&:itself), validate: true

  belongs_to :plan
  belongs_to :created_by_admin, class_name: "AdminUser", optional: true

  validates :current_period_start, :current_period_end, presence: true
  validate :period_ends_after_it_starts

  scope :live, -> { where(status: LIVE_STATUSES) }
  scope :recent_first, -> { order(current_period_start: :desc, created_at: :desc) }
  scope :expiring_within, ->(days) {
    live.where(current_period_end: Date.current..days.days.from_now.to_date)
  }

  # What the API gates on. A subscription whose period has run out is not
  # entitled, whatever the stored status says — otherwise a firm keeps access
  # indefinitely just because nobody in ops got round to marking it lapsed.
  def entitled?
    status.in?(LIVE_STATUSES) && current_period_end >= Date.current
  end

  def expired? = current_period_end < Date.current

  def days_remaining = (current_period_end - Date.current).to_i

  def renew!(actor: nil)
    new_start = [ current_period_end + 1.day, Date.current ].max

    update!(
      status: :active,
      current_period_start: new_start,
      current_period_end: new_start + plan.period_length - 1.day,
      amount: plan.price
    )

    AuditEvent.record!(subject: self, firm:, action: "subscription.renewed", actor:,
                       metadata: { plan: plan.code, until: current_period_end.to_s })
    self
  end

  def cancel!(reason:, actor: nil)
    update!(status: :cancelled, cancelled_at: Time.current, cancel_reason: reason)

    AuditEvent.record!(subject: self, firm:, action: "subscription.cancelled", actor:,
                       metadata: { reason: })
    self
  end

  # Switching plans supersedes the current subscription rather than mutating it,
  # so the firm's billing history stays readable.
  def self.switch_plan!(firm:, plan:, actor: nil, starts_on: Date.current)
    transaction do
      firm.subscriptions.live.each { |s| s.update!(status: :cancelled, cancelled_at: Time.current) }

      created = firm.subscriptions.create!(
        plan:,
        status: :active,
        current_period_start: starts_on,
        current_period_end: starts_on + plan.period_length - 1.day,
        amount: plan.price,
        created_by_admin: actor
      )

      AuditEvent.record!(subject: created, firm:, action: "subscription.plan_changed", actor:,
                         metadata: { plan: plan.code })
      created
    end
  end

  private

  def period_ends_after_it_starts
    return if current_period_start.blank? || current_period_end.blank?
    return if current_period_end >= current_period_start

    errors.add(:current_period_end, "must be on or after the period start")
  end
end
