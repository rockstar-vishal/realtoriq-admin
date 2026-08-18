# frozen_string_literal: true

# A physical building holding resale and rental listings.
#
# Firm-owned rather than a global master: brokers create these inline from the
# property form, and one broker's typo must not reach every other firm's
# dropdown. That was a deliberate trade — duplication across firms in exchange
# for no moderation queue.
class Building < ApplicationRecord
  include FirmScoped

  belongs_to :city
  belongs_to :locality

  # A building with listings on it cannot be removed — the listings are the
  # point, and orphaning them would lose the address.
  has_many :properties, -> { unscope(where: :firm_id) }, dependent: :restrict_with_error

  validates :name, presence: true, length: { maximum: 160 }
  validates :name, uniqueness: { scope: %i[firm_id locality_id], case_sensitive: false }
  validates :lat, numericality: { in: -90..90 }, allow_nil: true
  validates :lng, numericality: { in: -180..180 }, allow_nil: true

  validate :locality_belongs_to_the_chosen_city

  scope :search, ->(term) {
    next all if term.blank?

    where("buildings.name ILIKE ?", "%#{sanitize_sql_like(term.to_s.strip)}%")
  }

  scope :alphabetical, -> { order(:name) }

  def display_name = "#{name} — #{locality&.name}"

  private

  # The design's modal pre-fills the city and then asks for a locality within
  # it, so a mismatch means the client sent something the user never picked.
  #
  # Compares the associations, not the foreign keys: an unsaved city is present
  # as an object while its id is still nil, and comparing ids would call two
  # different cities equal because both are nil.
  def locality_belongs_to_the_chosen_city
    return if locality.blank? || city.blank? || locality.city == city

    errors.add(:locality_id, "is not in the selected city")
  end
end
