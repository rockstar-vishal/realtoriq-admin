# frozen_string_literal: true

# One turbo visit pass for a lead. Refresh is allowed once every six hours.
# The stored snapshot is what the lead screen shows between refreshes.
class LeadVisitPass < ApplicationRecord
  include FirmScoped

  REFRESH_AFTER = 6.hours

  belongs_to :lead, -> { unscope(where: :firm_id) }
  belongs_to :project, -> { unscope(where: :firm_id) }
  belongs_to :user, -> { unscope(where: :firm_id) }

  belongs_to_same_firm :lead, :project, :user, allow_marketplace: true

  validates :pass_code, uniqueness: true, allow_nil: true
  validates :phone_suffix, presence: true, format: { with: /\A\d{5}\z/, message: "must be exactly 5 digits" }
  validates :tentative_visit_planned, presence: true
  validates :turbo_status, inclusion: { in: %w[pending unused used duplicate] }
  validate :pass_code_once_issued

  def refresh_allowed?
    last_fetched_at.nil? || last_fetched_at <= REFRESH_AFTER.ago
  end

  def next_refresh_at
    return if last_fetched_at.nil?

    last_fetched_at + REFRESH_AFTER
  end

  private

  def pass_code_once_issued
    return if turbo_status == "pending" || pass_code.present?

    errors.add(:pass_code, "can't be blank")
  end
end
