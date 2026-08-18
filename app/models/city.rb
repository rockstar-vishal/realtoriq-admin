# frozen_string_literal: true

# Global master — every firm sees the same city list, maintained by ops.
class City < ApplicationRecord
  # Official state codes. Firm codes read CP-MH-04218, and "MH" is not
  # derivable by truncating "Maharashtra" — Madhya Pradesh would collide.
  STATE_CODES = {
    "Maharashtra" => "MH", "Karnataka" => "KA", "Delhi" => "DL", "Haryana" => "HR",
    "Uttar Pradesh" => "UP", "Gujarat" => "GJ", "Tamil Nadu" => "TN", "Telangana" => "TG",
    "West Bengal" => "WB", "Rajasthan" => "RJ", "Madhya Pradesh" => "MP", "Punjab" => "PB",
    "Kerala" => "KL", "Goa" => "GA", "Andhra Pradesh" => "AP", "Bihar" => "BR",
    "Odisha" => "OD", "Chandigarh" => "CH", "Jharkhand" => "JH", "Assam" => "AS",
    "Uttarakhand" => "UK", "Chhattisgarh" => "CG", "Himachal Pradesh" => "HP"
  }.freeze

  has_many :localities, dependent: :restrict_with_error
  has_many :firms, dependent: :nullify

  validates :name, presence: true, uniqueness: { scope: :state, case_sensitive: false }
  validates :state, presence: true
  validates :state_code, presence: true, length: { is: 2 }
  validates :slug, presence: true, uniqueness: true

  before_validation :assign_slug
  before_validation :assign_state_code

  scope :active, -> { where(active: true) }
  scope :alphabetical, -> { order(:name) }

  def to_param = slug

  def display_name = "#{name}, #{state}"

  private

  def assign_slug
    self.slug = slug.presence || [ name, state ].compact.join("-").parameterize
  end

  # Falls back to the first two letters for a state not in the table, so adding
  # one never blocks ops — they can correct it from the masters screen.
  def assign_state_code
    self.state_code = (
      state_code.presence || STATE_CODES[state.to_s.strip] || state.to_s.first(2)
    ).to_s.upcase.presence
  end
end
