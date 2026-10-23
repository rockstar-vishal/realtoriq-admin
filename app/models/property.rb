# frozen_string_literal: true

# A resale or rental listing. Distinct from Project, which is developer stock.
class Property < ApplicationRecord
  include FirmScoped
  include InventoryCode
  include PortalListingCodes
  include Inventory::PublicSlug
  include IndiaPin
  self.inventory_code_prefix = "H"
  self.inventory_code_index = "index_properties_on_code"

  LISTING_FOR = %w[sale rent].freeze
  FLOOR_BANDS = %w[lower middle higher].freeze
  STATUSES = %w[available booked sold_out].freeze

  enum :listing_for, LISTING_FOR.index_by(&:itself), prefix: :for
  enum :status, STATUSES.index_by(&:itself), validate: true

  # The old grouping. New listings leave it blank. Nothing in this model reads it.
  belongs_to :building, optional: true
  belongs_to :city
  belongs_to :locality
  belongs_to :typology
  belongs_to :created_by_user, -> { unscope(where: :firm_id) },
    class_name: "User", optional: true
  belongs_to_same_firm :created_by_user

  has_many :lead_properties, -> { unscope(where: :firm_id) }, dependent: :destroy
  has_many :lead_visit_properties, -> { unscope(where: :firm_id) }, dependent: :restrict_with_error

  has_many_attached :photos

  PIN_FREE_CHANGES = %w[status listed_on_marketplace on_website].freeze

  validates :building_name, presence: true, length: { maximum: 160 }
  validates :listing_for, inclusion: { in: LISTING_FOR }
  validates :floor_band, inclusion: { in: FLOOR_BANDS }, allow_blank: true
  validates :price, numericality: { greater_than: 0, only_integer: true }
  validates :lat, numericality: { in: -90..90 }, allow_nil: true
  validates :lng, numericality: { in: -180..180 }, allow_nil: true
  validates :carpet_area_sqft,
    numericality: { greater_than: 0, only_integer: true }, allow_nil: true
  validates :area_value, numericality: { greater_than: 0 }, allow_nil: true
  validates :area_unit, inclusion: { in: AreaUnits::CODES }
  validate :plot_is_for_sale
  validate :area_unit_matches_category
  validate :details_match_configuration
  validate :locality_belongs_to_the_chosen_city
  validate :pin_required_on_form, on: :listing_form

  before_validation :sync_area
  before_validation :normalise_listing

  # The card title is "{typology} in {locality}" — that whole string, either
  # half of it, the building name, or the description. The city is not part
  # of the title and is not searched.
  scope :search, ->(term) {
    next all if term.blank?

    pattern = "%#{sanitize_sql_like(term.to_s.strip)}%"
    left_joins(:typology, :locality).where(<<~SQL.squish, q: pattern)
      properties.building_name ILIKE :q
      OR properties.description ILIKE :q
      OR typologies.name ILIKE :q
      OR localities.name ILIKE :q
      OR CONCAT_WS(' in ', NULLIF(typologies.name, ''), NULLIF(localities.name, '')) ILIKE :q
    SQL
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

    where(city_id:)
  }

  scope :in_locality, ->(locality_id) {
    next all if locality_id.blank?

    where(locality_id:)
  }

  scope :newest_first, -> { order(created_at: :desc) }

  # Homes stay "{configuration} in {locality}". Commercial and plot titles
  # put the area between the configuration and the place.
  def title
    place = locality&.name
    head = if typology.nil? || typology.residential?
      typology&.name
    else
      [ typology.name, area_phrase ].compact_blank.join(" · ")
    end
    [ head, place ].compact_blank.join(" in ").presence || building_name
  end

  # Derived, not stored: the two would drift the moment a price is corrected.
  def rate_per_sqft
    return nil if carpet_area_sqft.to_i.zero?

    (price.to_d / carpet_area_sqft).round
  end

  # Whole rupees per the unit the broker typed. Land uses guntha or acre,
  # not the converted square feet.
  def rate_per_unit
    return if area_value.blank? || area_value.to_d.zero?

    { amount: (price.to_d / area_value.to_d).round(0, :half_up).to_i, unit: area_unit }
  end

  def lease_yield_percent
    return unless pre_leased?

    rent = details.to_h["lease_monthly_rent"].to_i
    return if rent <= 0 || price.to_i <= 0

    percent = (rent.to_d * 12 / price.to_d) * 100
    percent.round(2, :half_up).to_s("F").sub(/\.?0+\z/, "")
  end

  def lease_payload
    return unless pre_leased?

    {
      monthly_rent: details.to_h["lease_monthly_rent"],
      lock_in_until: details.to_h["lock_in_until"],
      tenant_type: details.to_h["tenant_type"],
      yield_percent: lease_yield_percent
    }
  end

  def area_payload
    {
      value: AreaUnits.display_quantity(area_value),
      unit: area_unit,
      sqft: carpet_area_sqft,
      kind: typology&.area_kind || "carpet"
    }
  end

  def rental? = for_rent?

  def public_slug_source
    title.presence || building_name
  end

  private

  # Compares the associations, not the foreign keys: an unsaved city is present
  # as an object while its id is still nil, and comparing ids would call two
  # different cities equal because both are nil.
  def locality_belongs_to_the_chosen_city
    return if locality.blank? || city.blank? || locality.city == city

    errors.add(:locality_id, "is not in the selected city")
  end

  # Status, the marketplace switch, and the website switch are not the form.
  # A booking that only marks the listing booked must not demand a pin.
  def pin_required_on_form
    return if has_pin?
    return if persisted? && changes.keys.any? && (changes.keys - PIN_FREE_CHANGES).empty?

    errors.add(:base, IndiaPin::PIN_MESSAGE)
  end

  # An old client still sends carpet_area_sqft and nothing else. Once the
  # backfill has filled area_value, recomputing from that stale value would
  # throw the edit away.
  def sync_area
    if will_save_change_to_carpet_area_sqft? && !will_save_change_to_area_value?
      self.area_value = carpet_area_sqft
      self.area_unit = "sqft"
    end

    if area_value.present?
      self.area_unit = "sqft" if area_unit.blank?
      return unless AreaUnits::CODES.include?(area_unit)
      return if typology && !typology.land? && area_unit != "sqft"

      self.carpet_area_sqft = AreaUnits.to_sqft(area_value, area_unit)
    elsif carpet_area_sqft.present? && area_value.blank?
      self.area_value = carpet_area_sqft
      self.area_unit = "sqft"
    end
  end

  def normalise_listing
    self.details = {} if details.blank?
    return if typology.nil?

    self.floor_band = nil unless typology.uses_floor_band?
    self.pre_leased = false unless typology.commercial? && for_sale?
    return if pre_leased?

    self.details = details.stringify_keys.except(*Inventory::DetailSpecs::LEASE_KEYS)
  end

  def plot_is_for_sale
    return unless typology&.land? && for_rent?

    errors.add(:base, "Plot & Land can only be listed for sale.")
  end

  def area_unit_matches_category
    return if area_value.blank? || typology.nil? || typology.land?
    return if area_unit == "sqft"

    errors.add(:area_unit, "must be sq ft for this configuration")
  end

  def details_match_configuration
    result = Inventory::DetailSpecs.clean(typology&.code, details, pre_leased: pre_leased?)
    if result.errors.any?
      result.errors.each { |message| errors.add(:details, message) }
    else
      self.details = result.values
    end
  end

  def area_phrase
    return if area_value.blank?

    "#{AreaUnits.display_quantity(area_value)} #{AreaUnits::LABELS.fetch(area_unit, area_unit)}"
  end
end
