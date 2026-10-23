# frozen_string_literal: true

# Global master. Category lives here: Residential, Commercial, or Plot & Land.
# A listing, a lead and a project row all take their category from the
# configuration they point at.
class Typology < ApplicationRecord
  CATEGORY_ORDER = %w[residential commercial land].freeze
  CATEGORIES = CATEGORY_ORDER
  LABELS = {
    "residential" => "Residential",
    "commercial" => "Commercial",
    "land" => "Plot & Land"
  }.freeze
  PRICE_NAMES = {
    "residential" => "Homes",
    "commercial" => "Commercial",
    "land" => "Plots"
  }.freeze
  # Names that describe a category, not a configuration. They never become
  # an alias, and they are not used as a variant label.
  GENERIC_NAME_KEYS = %w[commercial others other residential].freeze
  FLOORLESS = %w[villa row_house].freeze

  def self.row(name, code, bedrooms, category, sort_order)
    {
      name:, code:,
      bedrooms: bedrooms && BigDecimal(bedrooms),
      category:, sort_order:
    }.freeze
  end

  CANONICAL = [
    row("1 RK", "1_rk", "1.0", "residential", 0),
    row("1 BHK", "1_bhk", "1.0", "residential", 1),
    row("1.5 BHK", "1_5_bhk", "1.5", "residential", 2),
    row("2 BHK", "2_bhk", "2.0", "residential", 3),
    row("2.5 BHK", "2_5_bhk", "2.5", "residential", 4),
    row("3 BHK", "3_bhk", "3.0", "residential", 5),
    row("3.5 BHK", "3_5_bhk", "3.5", "residential", 6),
    row("4 BHK", "4_bhk", "4.0", "residential", 7),
    row("4.5 BHK", "4_5_bhk", "4.5", "residential", 8),
    row("5 BHK", "5_bhk", "5.0", "residential", 9),
    row("5+ BHK", "5_plus_bhk", "5.0", "residential", 10),
    row("Villa", "villa", nil, "residential", 11),
    row("Penthouse", "penthouse", nil, "residential", 12),
    row("Row house", "row_house", nil, "residential", 13),
    row("Office", "office", nil, "commercial", 100),
    row("Shop", "shop", nil, "commercial", 101),
    row("Showroom", "showroom", nil, "commercial", 102),
    row("Warehouse / Godown", "warehouse", nil, "commercial", 103),
    row("Industrial shed", "industrial_shed", nil, "commercial", 104),
    row("Other commercial", "other_commercial", nil, "commercial", 105),
    row("Residential plot", "residential_plot", nil, "land", 200),
    row("Commercial plot", "commercial_plot", nil, "land", 201),
    row("Industrial plot", "industrial_plot", nil, "land", 202),
    row("Agricultural land", "agricultural_land", nil, "land", 203)
  ].freeze

  validates :name, presence: true, uniqueness: { case_sensitive: false }
  validates :code, presence: true, uniqueness: true
  validates :category, inclusion: { in: CATEGORIES }

  belongs_to :merged_into, class_name: "Typology", optional: true
  has_many :configuration_aliases, dependent: :destroy

  before_validation :assign_code
  before_validation :confirm_category_from_admin
  validate :category_change_is_allowed, on: :update

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:sort_order, :name) }
  scope :pickable, -> { active.where(merged_into_id: nil) }

  def self.label_for(code)
    LABELS[code.to_s]
  end

  def self.generic_name?(name)
    GENERIC_NAME_KEYS.include?(Realtoriq::NameKey.call(name))
  end

  # Code first, then the exact name. `active_on_create` is false for the
  # commercial and land rows the production backfill adds.
  def self.upsert_canonical!(row, active_on_create:)
    record = find_by(code: row[:code]) || find_by(name: row[:name]) || new
    creating = record.new_record?
    record.name = row[:name]
    record.code = row[:code]
    record.bedrooms = row[:bedrooms]
    record.category = row[:category]
    record.sort_order = row[:sort_order]
    record.needs_review = false
    record.category_confirmed_at ||= Time.current
    record.active = active_on_create if creating
    record.save!
    record
  end

  def category_label
    self.class.label_for(category)
  end

  def residential? = category == "residential"
  def commercial? = category == "commercial"
  def land? = category == "land"

  def area_kind
    land? ? "plot" : "carpet"
  end

  # Floor band stays for flats, penthouses and offices. Villa, row house,
  # every other commercial configuration, and every plot clear it.
  def uses_floor_band?
    code == "office" || (residential? && FLOORLESS.exclude?(code))
  end

  def referenced?
    Property.unscoped.exists?(typology_id: id) ||
      LeadTypology.exists?(typology_id: id) ||
      ProjectTypology.exists?(typology_id: id)
  end

  # Repoint every listing, lead and project row, then hide this configuration.
  # A confirmed configuration cannot cross categories. An active in-use source
  # makes an inactive target active, so the old project editor still sees it.
  def merge_into!(target, admin: nil)
    if target.nil? || target.id == id || target.merged_into_id.present?
      errors.add(:base, "Choose a configuration that is still in the list")
      raise ActiveRecord::RecordInvalid, self
    end
    if category != target.category && category_confirmed_at.present?
      errors.add(:base, "A confirmed configuration can only merge into the same category")
      raise ActiveRecord::RecordInvalid, self
    end

    @alias_written = false
    @adopted_leads = []
    transaction do
      target.update!(active: true) if active? && referenced? && !target.active?
      repoint_properties(target)
      lead_ids = repoint_leads(target)
      repoint_project_rows(target)
      @alias_written = remember_alias(target, admin)
      @adopted_leads = adopt_leads(target, lead_ids)
      update!(merged_into: target, active: false)
      AuditEvent.record!(
        subject: self, action: "typology.merged", actor: admin,
        metadata: merge_metadata(target)
      )
    end
    self
  end

  def alias_written?
    @alias_written
  end

  def adopted_leads
    @adopted_leads || []
  end

  private

  def assign_code
    self.code = code.presence || name.to_s.parameterize(separator: "_")
  end

  # The admin form is a deliberate choice of category. Seeds and the backfill
  # set category_confirmed_at themselves. A resolver fallback must not, so
  # this is not a blanket callback on every category write.
  def confirm_category_from_admin
    return if Current.admin_user.nil?
    return if category_confirmed_at.present? && !will_save_change_to_category?

    self.category_confirmed_at = Time.current
  end

  def category_change_is_allowed
    return unless will_save_change_to_category?
    return if category_confirmed_at_in_database.nil?
    return unless referenced?

    errors.add(:category,
      "can't change once listings or leads use this configuration. " \
      "Merge it into another configuration instead.")
  end

  def repoint_properties(target)
    Property.unscoped.where(typology_id: id).update_all(typology_id: target.id, updated_at: Time.current)
  end

  def repoint_leads(target)
    lead_ids = LeadTypology.where(typology_id: id).distinct.pluck(:lead_id)
    lead_ids.each do |lead_id|
      if LeadTypology.where(lead_id:, typology_id: target.id).exists?
        LeadTypology.where(lead_id:, typology_id: id).delete_all
      else
        LeadTypology.where(lead_id:, typology_id: id)
          .update_all(typology_id: target.id, updated_at: Time.current)
      end
    end
    lead_ids
  end

  # Only a cross-category merge can leave a lead holding the wrong category.
  def adopt_leads(target, lead_ids)
    return [] if category == target.category || lead_ids.empty?

    Lead.unscoped.where(id: lead_ids).map { |lead|
      [ lead, lead.adopt_category_from_configurations! ]
    }
  end

  def repoint_project_rows(target)
    proposed = self.class.generic_name?(name) ? nil : name
    ProjectTypology.where(typology_id: id).find_each do |row|
      row.typology = target
      row.label = ProjectTypology.stored_label(proposed, target)
      clash = ProjectTypology.where(project_id: row.project_id, typology_id: target.id)
        .where.not(id: row.id)
        .where("lower(COALESCE(label, '')) = ?", row.label.to_s.downcase)
        .exists?
      clash ? row.destroy! : row.save!
    end
  end

  # A review decision is a person's correction and wins over a merge. A merge
  # alias can move when the same name is merged again.
  def remember_alias(target, admin)
    return false if self.class.generic_name?(name)

    alias_row = ConfigurationAlias.find_or_initialize_by(key: Realtoriq::NameKey.call(name))
    return false if alias_row.persisted? && alias_row.source != "merge"

    alias_row.update!(typology: target, source: "merge", created_by_admin: admin)
    true
  end

  def merge_metadata(target)
    metadata = { source_id: id, target_id: target.id, source_name: name, target_name: target.name }
    metadata[:categories] = { from: category, to: target.category } if category != target.category
    metadata
  end
end
