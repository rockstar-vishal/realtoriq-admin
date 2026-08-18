# frozen_string_literal: true

# Money actually received. May be tied to an invoice, or left unlinked — the
# design offers "Unlinked payment" explicitly.
class Collection < ApplicationRecord
  include FirmScoped

  MODES = %w[neft_rtgs upi cheque cash].freeze

  enum :mode, MODES.index_by(&:itself), validate: true

  belongs_to :booking, -> { unscope(where: :firm_id) }
  belongs_to :invoice, -> { unscope(where: :firm_id) }, optional: true

  has_one_attached :proof

  validates :received_on, presence: true
  validates :amount, numericality: { greater_than: 0, only_integer: true }
  validate :invoice_belongs_to_the_same_booking

  scope :recent_first, -> { order(received_on: :desc, created_at: :desc) }

  def linked? = invoice_id.present?

  private

  # A payment filed against another booking's invoice would corrupt both.
  def invoice_belongs_to_the_same_booking
    return if invoice.blank? || invoice.booking_id == booking_id

    errors.add(:invoice_id, "belongs to a different booking")
  end
end
