# frozen_string_literal: true

# Developer inventory — new construction a broker sells on commission.
# Distinct from Property, which is resale and rental stock.
class Project < ApplicationRecord
  include FirmScoped
  include InventoryCode
  include PortalListingCodes
  self.inventory_code_prefix = "P"
  self.inventory_code_index = "index_projects_on_code"

  # Catalog rows synced from turbo-rails8 have no firm. FirmScoped's default
  # clause is `firm_id IS NULL` when no tenant is set, which would reveal those
  # rows. `none` keeps that case empty. A signed-in firm still sees only its
  # own rows; marketplace reads go through `.marketplace`.
  default_scope do
    Current.firm.nil? && !Current.firm_scope_bypassed ? none : all
  end

  belongs_to :firm, optional: true

  # FirmScoped's belongs_to is required. That validator is built before this
  # redeclaration and still rejects a marketplace row. The marketplace? check
  # below is the one that stays.
  required_firm = _validators[:firm]&.select { |validator| validator.options[:message] == :required } || []
  required_firm.each { |validator| _validators[:firm].delete(validator) }
  _validate_callbacks.select { |callback| required_firm.include?(callback.filter) }.each do |callback|
    _validate_callbacks.delete(callback)
  end

  STATUSES = %w[active archived].freeze
  SOURCES = %w[own catalog].freeze
  # Shared with Inventory::ProjectSearch, so a pasted full name is never cut
  # short before it can match itself.
  NAME_MAX_LENGTH = 160

  enum :status, STATUSES.index_by(&:itself), validate: true
  enum :source, SOURCES.index_by(&:itself), prefix: :from, validate: true

  belongs_to :builder, -> { unscope(where: :firm_id) }
  belongs_to :city
  belongs_to :locality, optional: true

  has_many :project_typologies, -> { unscope(where: :firm_id) }, dependent: :destroy
  has_many :typologies, through: :project_typologies
  has_many :lead_projects, -> { unscope(where: :firm_id) }, dependent: :destroy
  has_many :lead_visit_projects, -> { unscope(where: :firm_id) }, dependent: :restrict_with_error

  # Photos live on the detail screen, not the create form — the design is
  # explicit about that, so they arrive through their own endpoint.
  has_many_attached :photos
  has_one_attached :brochure
  has_one_attached :brokerage_ladder

  validates :name, presence: true, length: { maximum: NAME_MAX_LENGTH }
  validates :firm, presence: true, unless: :marketplace?
  validates :starting_budget, numericality: { greater_than: 0, only_integer: true }
  validates :brokerage_percent,
    numericality: { greater_than: 0, less_than_or_equal_to: 100 }, allow_nil: true
  validates :lat, numericality: { in: -90..90 }, allow_nil: true
  validates :lng, numericality: { in: -180..180 }, allow_nil: true
  validate :has_a_possession_date_or_a_label
  validate :builder_is_available_to_this_firm
  validate :name_unique_within_source

  # Search box: name, builder, city, locality, RERA. The street address is not
  # searched — location means the city and locality on the card.
  TEXT_SEARCH_SQL = <<~SQL.squish.freeze
    projects.name ILIKE :q
    OR projects.rera_number ILIKE :q
    OR builders.name ILIKE :q
    OR cities.name ILIKE :q
    OR localities.name ILIKE :q
  SQL

  scope :search, ->(term) {
    next all if term.blank?

    pattern = "%#{sanitize_sql_like(term.to_s.strip)}%"
    left_joins(:builder, :city, :locality).where(TEXT_SEARCH_SQL, q: pattern)
  }

  # Advanced-search "project name". Substring of the name only, so it can sit
  # beside the other drawer filters. `q` cannot: a drawer param drops it.
  scope :named_like, ->(term) {
    next all if term.blank?

    pattern = "%#{sanitize_sql_like(term.to_s.strip)}%"
    where("projects.name ILIKE ?", pattern)
  }

  scope :possession_before, ->(date) {
    next all if date.blank?

    where(possession_on: ..date)
  }

  # A project qualifies if any of its typologies starts inside the window —
  # a broker filtering by budget wants the project that has *something* they
  # can sell at that price, not one whose every configuration fits.
  scope :budget_between, ->(min, max) {
    next all if min.blank? && max.blank?

    typologies = ProjectTypology.unscoped.select(:project_id)
    typologies = typologies.where(starting_price: min..) if min.present?
    typologies = typologies.where(starting_price: ..max) if max.present?

    where(id: typologies)
  }

  scope :for_typologies, ->(ids) {
    next all if ids.blank?

    where(id: ProjectTypology.unscoped.where(typology_id: ids).select(:project_id))
  }

  # NULL brokerage drops out of a range — a project that does not disclose
  # percent is not "between 2 and 4".
  scope :brokerage_between, ->(min, max) {
    next all if min.blank? && max.blank?

    scope = where.not(brokerage_percent: nil)
    scope = scope.where(brokerage_percent: min.to_d..) if min.present?
    scope = scope.where(brokerage_percent: ..max.to_d) if max.present?
    scope
  }

  scope :alphabetical, -> { order(:name) }

  # Shared marketplace stock. One row per turbo project code, visible to every
  # firm, never mixed into My Projects.
  def self.marketplace
    unscoped.where(firm_id: nil, source: "catalog", status: "active")
  end

  # Marketplace browse order for one firm. Until nearby matching is on, bands
  # are the primary locality, the firm's other localities, the rest of those
  # cities, then everywhere else, newest first inside a band. Once it is on
  # and a tagged locality has a center, neighbor localities sit between the
  # tagged ones and the rest of the city, and each band is nearest to a
  # tagged center first. A project with a city and no locality matches the
  # city band only — `locality_id =` does not match NULL.
  #
  # Chain this on an existing marketplace relation. A fresh Project query hits
  # FirmScoped and the catalog guard scope and returns no catalog rows.
  # No locality on the firm means newest first, which is what the home strip
  # showed before firms had a pin.
  scope :relevant_to, ->(firm) {
    primary_id = firm&.locality_id
    next order(created_at: :desc, id: :desc) if primary_id.blank?

    extra_ids = firm.firm_localities.where.not(locality_id: primary_id).pluck(:locality_id)
    tagged_ids = [ primary_id, *extra_ids ]
    city_ids = Locality.where(id: tagged_ids).distinct.pluck(:city_id)
    nearby_on = NearbyMatching.enabled?
    neighbor_ids = if nearby_on
      LocalityNeighbor.where(locality_id: tagged_ids).where.not(neighbor_locality_id: tagged_ids).distinct.pluck(:neighbor_locality_id)
    else
      []
    end

    whens = [ "WHEN projects.locality_id = :primary_id THEN 0" ]
    binds = { primary_id: }
    band = 1
    if extra_ids.any?
      whens << "WHEN projects.locality_id IN (:extra_ids) THEN #{band}"
      binds[:extra_ids] = extra_ids
      band += 1
    end
    if neighbor_ids.any?
      whens << "WHEN projects.locality_id IN (:neighbor_ids) THEN #{band}"
      binds[:neighbor_ids] = neighbor_ids
      band += 1
    end
    if city_ids.any?
      whens << "WHEN projects.city_id IN (:city_ids) THEN #{band}"
      binds[:city_ids] = city_ids
      band += 1
    end

    rank = sanitize_sql_array([ "CASE #{whens.join(' ')} ELSE #{band} END", binds ])
    centers = nearby_on ? Locality.where(id: tagged_ids).where.not(lat: nil, lng: nil).to_a : []
    next order(Arel.sql(rank), created_at: :desc, id: :desc) if centers.empty?

    distance = sanitize_sql_array([ "#{Project.distance_to_centers_sql(centers)} ASC NULLS LAST" ])
    order(Arel.sql(rank), Arel.sql(distance), created_at: :desc, id: :desc)
  }

  def self.distance_to_centers_sql(centers)
    parts = centers.map { |center|
      sanitize_sql_array(
        [ Inventory::Geo.haversine_sql(usable_lat_sql, usable_lng_sql), { clat: center.lat.to_f, clng: center.lng.to_f } ]
      )
    }
    "LEAST(#{parts.join(', ')})"
  end

  def self.usable_lat_sql
    "CASE WHEN #{usable_pin_sql} THEN projects.lat ELSE (SELECT localities.lat FROM localities WHERE localities.id = projects.locality_id) END"
  end

  def self.usable_lng_sql
    "CASE WHEN #{usable_pin_sql} THEN projects.lng ELSE (SELECT localities.lng FROM localities WHERE localities.id = projects.locality_id) END"
  end

  # A pin inside Maharashtra and within about 20 km of its locality center.
  # Degree checks stand in for the haversine so the ORDER BY stays one expression.
  def self.usable_pin_sql
    <<~SQL.squish
      projects.lat BETWEEN #{Inventory::Geo::LAT_RANGE.begin} AND #{Inventory::Geo::LAT_RANGE.end}
      AND projects.lng BETWEEN #{Inventory::Geo::LNG_RANGE.begin} AND #{Inventory::Geo::LNG_RANGE.end}
      AND (
        (SELECT localities.lat FROM localities WHERE localities.id = projects.locality_id) IS NULL
        OR (
          abs(projects.lat - (SELECT localities.lat FROM localities WHERE localities.id = projects.locality_id)) <= 0.2
          AND abs(projects.lng - (SELECT localities.lng FROM localities WHERE localities.id = projects.locality_id)) <= 0.25
        )
      )
    SQL
  end

  # FirmScoped#across_firms only drops the firm_id clause. The guard scope
  # above is `none` when no tenant is set, and that would make every
  # cross-firm read empty. Unscope both.
  def self.across_firms
    unscoped
  end

  def marketplace?
    firm_id.nil? && from_catalog?
  end

  # Derived, never stored: a stored band can end up disagreeing with the rows
  # it came from.
  def price_band
    prices = project_typologies.filter_map(&:starting_price)
    prices.empty? ? nil : { from: prices.min, to: prices.max }
  end

  def area_band
    areas = project_typologies.filter_map(&:starting_carpet_sqft)
    areas.empty? ? nil : { from: areas.min, to: areas.max }
  end

  def promo_live? = promo_text.present? && (promo_ends_on.nil? || promo_ends_on >= Date.current)

  def possession_display = possession_label.presence || possession_on&.strftime("%b %Y")

  # Unweighted mean of configuration rate_per_sqft where both price and carpet
  # exist. Half-up once. Null when no configuration can produce a rate.
  def avg_psf
    rates = project_typologies.filter_map(&:rate_per_sqft)
    return nil if rates.empty?

    (rates.sum.to_d / rates.size).round(0, :half_up).to_i
  end

  private

  def has_a_possession_date_or_a_label
    return if possession_on.present? || possession_label.present?

    errors.add(:possession_on, "is required unless a label like \"Ready\" is given")
  end

  # A builder from another firm's private list would leak its existence.
  def builder_is_available_to_this_firm
    return if builder.blank? || builder.global? || builder.firm_id == firm_id

    errors.add(:builder_id, "is not available to this firm")
  end

  # Unique case-insensitively inside own, and separately inside catalog. The
  # same name may exist once in each list.
  def name_unique_within_source
    return if name.blank? || firm_id.blank? || source.blank?

    clash = self.class.unscoped.where(firm_id:, source:)
      .where("LOWER(name) = ?", name.to_s.downcase)
    clash = clash.where.not(id:) if id.present?

    errors.add(:name, "has already been taken") if clash.exists?
  end
end
