# frozen_string_literal: true

# Brokerage raised against a booking.
#
# The number is entered by the broker rather than generated, so it matches the
# invoice they actually issued outside the system.
class Invoice < ApplicationRecord
  include FirmScoped

  STATUSES = %w[raised cancelled].freeze

  enum :status, STATUSES.index_by(&:itself), validate: true

  belongs_to :booking, -> { unscope(where: :firm_id) }
  has_many :collections, -> { unscope(where: :firm_id) }, dependent: :nullify

  validates :number, presence: true
  validates :number, uniqueness: { scope: :firm_id, case_sensitive: false }
  validates :issued_on, presence: true
  validates :amount, numericality: { greater_than: 0, only_integer: true }

  before_validation :normalise_number

  scope :raised, -> { where(status: :raised) }
  scope :recent_first, -> { order(issued_on: :desc, created_at: :desc) }

  def collected_total = collections.sum(:amount)

  # What may still be collected against this invoice specifically.
  def collectable_balance = amount - collected_total

  private

  def normalise_number
    self.number = number.to_s.strip.presence
  end
end
