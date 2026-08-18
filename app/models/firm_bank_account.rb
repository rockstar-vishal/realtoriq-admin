# frozen_string_literal: true

# The account printed on invoices the broker raises from a booking.
class FirmBankAccount < ApplicationRecord
  include FirmScoped

  # Encrypted at the application layer: ops need to enter and correct it, but a
  # database dump shouldn't hand over every broker's account number. Deterministic
  # so we can still detect a duplicate entry.
  encrypts :account_number, deterministic: true

  validates :account_number, presence: true, length: { minimum: 6, maximum: 20 }
  validates :ifsc, presence: true, format: {
    with: /\A[A-Z]{4}0[A-Z0-9]{6}\z/,
    message: "is not a valid IFSC code"
  }
  validates :bank_name, :holder_name, presence: true

  before_validation :normalise

  def masked_account_number
    return "" if account_number.blank?
    return account_number if account_number.length <= 4

    "#{'x' * (account_number.length - 4)}#{account_number.last(4)}"
  end

  private

  def normalise
    self.account_number = account_number.to_s.gsub(/\s/, "").presence
    self.ifsc = ifsc.to_s.upcase.gsub(/\s/, "").presence
  end
end
