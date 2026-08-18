# frozen_string_literal: true

# Developer inventory — new construction a broker sells on commission.
# Distinct from Property, which is resale and rental stock.
class Project < ApplicationRecord
  include FirmScoped

  STATUSES = %w[active archived].freeze
  SOURCES = %w[own catalog].freeze

  enum :status, STATUSES.index_by(&:itself), validate: true
  enum :source, SOURCES.index_by(&:itself), prefix: :from, validate: true

  belongs_to :builder, -> { unscope(where: :firm_id) }
  belongs_to :city
  belongs_to :locality, optional: true

  has_many :project_typologies, -> { unscope(where: :firm_id) }, dependent: :destroy
  has_many :typologies, through: :project_typologies

  # Photos live on the detail screen, not the create form — the design is
  # explicit about that, so they arrive through their own endpoint.
  has_many_attached :photos
  has_one_attached :brochure

  validates :name, presence: true, length: { maximum: 160 }
  validates :starting_budget, numericality: { greater_than: 0, only_integer: true }
  validates :brokerage_percent,
    numericality: { greater_than: 0, less_than_or_equal_to: 100 }, allow_nil: true
  validates :lat, numericality: { in: -90..90 }, allow_nil: true
  validates :lng, numericality: { in: -180..180 }, allow_nil: true
  validate :has_a_possession_date_or_a_label
  validate :builder_is_available_to_this_firm

  scope :search, ->(term) {
    next all if term.blank?

    pattern = "%#{sanitize_sql_like(term.to_s.strip)}%"
    where("projects.name ILIKE :q OR projects.address ILIKE :q", q: pattern)
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

  scope :alphabetical, -> { order(:name) }

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
end
