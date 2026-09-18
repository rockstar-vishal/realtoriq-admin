# frozen_string_literal: true

# A resale or rental listing. Distinct from Project, which is developer stock.
class Property < ApplicationRecord
  include FirmScoped

  LISTING_FOR = %w[sale rent].freeze
  FLOOR_BANDS = %w[lower middle higher].freeze
  STATUSES = %w[available booked sold_out].freeze

  enum :listing_for, LISTING_FOR.index_by(&:itself), prefix: :for
  enum :status, STATUSES.index_by(&:itself), validate: true

  belongs_to :building
  belongs_to :typology
  belongs_to :created_by_user, -> { unscope(where: :firm_id) },
    class_name: "User", optional: true
  belongs_to_same_firm :created_by_user

  has_many :lead_properties, -> { unscope(where: :firm_id) }, dependent: :destroy

  has_many_attached :photos

  validates :listing_for, inclusion: { in: LISTING_FOR }
  validates :floor_band, inclusion: { in: FLOOR_BANDS }, allow_blank: true
  validates :price, numericality: { greater_than: 0, only_integer: true }
  validates :carpet_area_sqft,
    numericality: { greater_than: 0, only_integer: true }, allow_nil: true

  scope :search, ->(term) {
    next all if term.blank?

    pattern = "%#{sanitize_sql_like(term.to_s.strip)}%"
    joins(:building).where(
      "buildings.name ILIKE :q OR properties.description ILIKE :q", q: pattern
    )
  }

  scope :price_between, ->(min, max) {
    scope = all
    scope = scope.where(price: min..) if min.present?
    scope = scope.where(price: ..max) if max.present?
    scope
  }

  # NULL carpet drops out of a range — a listing without area is not "600–800".
  scope :carpet_between, ->(min, max) {
    next all if min.blank? && max.blank?

    scope = where.not(carpet_area_sqft: nil)
    scope = scope.where(carpet_area_sqft: min.to_i..) if min.present?
    scope = scope.where(carpet_area_sqft: ..max.to_i) if max.present?
    scope
  }

  scope :in_city, ->(city_id) {
    next all if city_id.blank?

    joins(:building).where(buildings: { city_id: })
  }

  scope :in_locality, ->(locality_id) {
    next all if locality_id.blank?

    joins(:building).where(buildings: { locality_id: })
  }

  scope :newest_first, -> { order(created_at: :desc) }

  # "2 BHK in Kharghar" — how the design labels a listing on the index card.
  def title
    [ typology&.name, building&.locality&.name ].compact_blank.join(" in ").presence ||
      building&.name
  end

  # Derived, not stored: the two would drift the moment a price is corrected.
  def rate_per_sqft
    return nil if carpet_area_sqft.to_i.zero?

    (price.to_d / carpet_area_sqft).round
  end

  def rental? = for_rent?
end
