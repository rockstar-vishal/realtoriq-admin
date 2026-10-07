# frozen_string_literal: true

# One Facebook leadgen id. The id is unique across every firm, so the same
# lead cannot be imported twice or into two firms.
class FacebookLeadImport < ApplicationRecord
  include FirmScoped

  STATUSES = %w[pending processing created failed dead duplicate].freeze
  MAX_RETRIES = 5

  enum :status, STATUSES.index_by(&:itself), validate: true, default: :pending

  belongs_to :facebook_page, -> { unscope(where: :firm_id) }
  belongs_to :facebook_lead_form, -> { unscope(where: :firm_id) }, optional: true
  belongs_to :lead, -> { unscope(where: :firm_id) }, optional: true
  belongs_to_same_firm :facebook_page, :facebook_lead_form, :lead

  validates :leadgen_id, presence: true
  validate :leadgen_id_is_globally_unique

  scope :recent, -> { order(created_at: :desc) }

  # True only for the worker that moved pending or failed → processing.
  def claim!
    now = Time.current
    claimed = self.class.across_firms.where(id:, status: %w[pending failed]).update_all(
      status: "processing",
      processing_started_at: now,
      updated_at: now
    )
    return false unless claimed == 1

    reload
    true
  end

  # True only on the transition into dead, so the digest is stamped once.
  def record_failure!(message:, details: {})
    was_dead = dead?
    new_count = retry_count + 1
    new_status = new_count >= MAX_RETRIES ? "dead" : "failed"

    update!(
      status: new_status,
      error_message: message.to_s.truncate(2000),
      error_details: details.merge("retry_count_at_failure" => new_count, "failed_at" => Time.current.iso8601),
      retry_count: new_count
    )

    !was_dead && dead?
  end

  def mark_created!(lead:, error_details: nil)
    attrs = {
      status: :created,
      lead:,
      processed_at: Time.current,
      error_message: nil
    }
    attrs[:error_details] = error_details if error_details
    update!(attrs)
  end

  def mark_duplicate!(lead: nil)
    attrs = { status: :duplicate, processed_at: Time.current }
    attrs[:lead] = lead if lead
    update!(attrs)
  end

  # Turned-off forms die quietly. No digest.
  def mark_skipped!(message:)
    update!(
      status: :dead,
      error_message: message.to_s.truncate(2000),
      error_details: {
        "skipped" => true,
        "reason" => message.to_s,
        "skipped_at" => Time.current.iso8601
      },
      retry_count: MAX_RETRIES,
      processed_at: Time.current,
      failure_alert_pending_at: nil
    )
  end

  # Failed and dead imports can be tried again from the Connect Facebook screen.
  def queue_retry!
    return false unless failed? || dead?

    update!(
      status: :pending,
      retry_count: 0,
      next_attempt_at: nil,
      error_message: nil,
      error_details: {},
      processed_at: nil,
      processing_started_at: nil,
      failure_alert_pending_at: nil
    )
    Facebook::ProcessLeadJob.perform_later(firm_id, id)
    true
  end

  def mark_dead_permanent!(message:, details: {}, alert: true)
    update!(
      status: :dead,
      error_message: message.to_s.truncate(2000),
      error_details: details.merge("permanent" => true, "failed_at" => Time.current.iso8601),
      retry_count: MAX_RETRIES,
      processed_at: Time.current,
      failure_alert_pending_at: alert ? Time.current : nil
    )
  end

  private

  def leadgen_id_is_globally_unique
    return if leadgen_id.blank?

    scope = self.class.across_firms.where(leadgen_id:)
    scope = scope.where.not(id:) if persisted?
    errors.add(:leadgen_id, "has already been taken") if scope.exists?
  end
end
