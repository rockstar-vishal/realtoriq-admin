# frozen_string_literal: true

# A subscription plan. `price` is whole rupees — see docs/schema.md.
class Plan < ApplicationRecord
  INTERVALS = %w[month year].freeze

  enum :interval, INTERVALS.index_by(&:itself), validate: true

  has_many :subscriptions, dependent: :restrict_with_error

  validates :name, presence: true
  validates :code, presence: true, uniqueness: { case_sensitive: false }
  validates :price, numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :max_devices, numericality: { greater_than: 0, only_integer: true }
  validates :max_users, numericality: { greater_than: 0, only_integer: true }, allow_nil: true

  before_validation :assign_code

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:sort_order, :price) }

  def period_length = year? ? 1.year : 1.month

  # "₹2,499/mo" in the drawer.
  def price_label
    return "Free" if price.zero?

    "₹#{ActiveSupport::NumberHelper.number_to_delimited(price, delimiter: ',', delimiter_pattern: /(\d+?)(?=(\d\d)+(\d)(?!\d))/)}/#{year? ? 'yr' : 'mo'}"
  end

  def feature_enabled?(key) = features[key.to_s].present?

  private

  def assign_code
    self.code = (code.presence || name.to_s.parameterize(separator: "_")).to_s.downcase
  end
end
