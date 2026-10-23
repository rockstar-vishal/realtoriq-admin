# frozen_string_literal: true

class ProjectTypology < ApplicationRecord
  LABEL_CLASH = "A configuration can appear twice only with different labels."
  LABEL_INDEX = "index_project_typologies_on_project_typology_and_label"
  REVIEW_NOTE_LIMIT = 255

  belongs_to :project, -> { unscope(where: :firm_id) }
  belongs_to :typology

  validates :starting_price,
    numericality: { greater_than: 0, only_integer: true }, allow_nil: true
  validates :starting_carpet_sqft,
    numericality: { greater_than: 0, only_integer: true }, allow_nil: true
  validates :area_value, numericality: { greater_than: 0 }, allow_nil: true
  validates :area_unit, inclusion: { in: AreaUnits::CODES }
  validates :label, length: { maximum: 60 }, allow_nil: true
  validates :review_note, length: { maximum: REVIEW_NOTE_LIMIT }, allow_nil: true
  validate :one_row_per_label
  validate :area_unit_matches_category

  before_validation :normalise_label
  before_validation :sync_area

  # ₹ per sqft, which is how brokers compare configurations against each other.
  def rate_per_sqft
    return nil if starting_price.blank? || starting_carpet_sqft.to_i.zero?

    (starting_price.to_d / starting_carpet_sqft).round
  end

  # The label alone when it already contains the configuration name
  # ("Grade A Boutique Office Spaces" on Office). Otherwise the name, then
  # the label ("2 BHK Ultima").
  def display_name
    return typology&.name if label.blank?
    return label if typology && Realtoriq::NameKey.call(label).include?(Realtoriq::NameKey.call(typology.name))

    "#{typology&.name} #{label}".strip
  end

  # A BHK disagreement has no label left to key an alias on, so the next
  # push would put the row straight back into review.
  def bhk_conflict_review?
    review_note.to_s.include?("disagrees with unit label")
  end

  def area_payload
    {
      value: AreaUnits.display_quantity(area_value),
      unit: area_unit,
      sqft: starting_carpet_sqft,
      kind: typology&.area_kind
    }
  end

  def self.stored_label(text, typology)
    raw = text.to_s.strip
    return nil if raw.blank? || typology.nil?
    return nil if Realtoriq::NameKey.call(raw) == Realtoriq::NameKey.call(typology.name)

    raw
  end

  private

  def normalise_label
    self.label = self.class.stored_label(label, typology)
  end

  def sync_area
    if will_save_change_to_starting_carpet_sqft? && !will_save_change_to_area_value?
      self.area_value = starting_carpet_sqft
      self.area_unit = "sqft"
    end

    if area_value.present?
      self.area_unit = "sqft" if area_unit.blank?
      return unless AreaUnits::CODES.include?(area_unit)

      self.starting_carpet_sqft = AreaUnits.to_sqft(area_value, area_unit)
    elsif starting_carpet_sqft.present? && area_value.blank?
      self.area_value = starting_carpet_sqft
      self.area_unit = "sqft" if area_unit.blank?
    end
  end

  def area_unit_matches_category
    return if area_value.blank? || typology.nil? || typology.land?
    return if area_unit == "sqft"

    errors.add(:area_unit, "must be sq ft for this configuration")
  end

  def one_row_per_label
    return if project_id.blank? || typology_id.blank?

    clash = self.class.where(project_id:, typology_id:)
      .where("lower(COALESCE(label, '')) = ?", label.to_s.downcase)
    clash = clash.where.not(id:) if persisted?
    return unless clash.exists?

    errors.add(:base, LABEL_CLASH)
  end
end
