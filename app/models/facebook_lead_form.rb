# frozen_string_literal: true

# One Meta lead form, owned by one firm. form_id is unique across every firm,
# so a second firm cannot claim it. A blank mapping uses Facebook's standard
# name, phone and email fields.
class FacebookLeadForm < ApplicationRecord
  include FirmScoped

  belongs_to :facebook_page, -> { unscope(where: :firm_id) }
  belongs_to :project, -> { unscope(where: :firm_id) }, optional: true
  belongs_to :property, -> { unscope(where: :firm_id) }, optional: true
  belongs_to :assigned_user, -> { unscope(where: :firm_id) }, class_name: "User", optional: true
  # Lead sources are a global master. They have no firm_id.
  belongs_to :lead_source, optional: true

  belongs_to_same_firm :facebook_page, :property, :assigned_user
  belongs_to_same_firm :project, allow_marketplace: true

  has_many :facebook_lead_imports, -> { unscope(where: :firm_id) }, dependent: :nullify

  validates :form_id, :form_name, presence: true
  validate :form_id_is_globally_unique
  validate :one_listing
  validate :lead_source_is_active, if: :lead_source_id_changed?

  scope :active_forms, -> { where(active: true) }

  def questions_list
    Array(questions).map { |question| question.stringify_keys }
  end

  def explicit_mappings?
    !Facebook::FieldMapper.soft_fallback?(field_mappings)
  end

  def ui_field_mappings
    return Facebook::FieldMapper.sanitize_mappings(field_mappings) if explicit_mappings?

    Facebook::FieldMapper.suggested_mappings(questions_list)
  end

  def mapping_summary
    mappings = Facebook::FieldMapper.sanitize_mappings(field_mappings)
    if mappings.empty?
      return "Using standard Name / Phone / Email"
    end

    question_keys = questions_list.filter_map { |question| Facebook::FieldMapper.question_key(question) }
    mapped_count = mappings.size
    ignored_count = [ question_keys.size - question_keys.count { |key| mappings.key?(key) }, 0 ].max
    labels = mappings.values.uniq.first(4).map { |target| Facebook::FieldMapper.target_label(target) }
    suffix = labels.any? ? " · #{labels.join(', ')}" : ""

    "#{mapped_count} mapped · #{ignored_count} ignored#{suffix}"
  end

  # Turning the form off does not need a listing. A listing that is present
  # still has to be usable, and an explicit map still needs Name and Mobile.
  def save_error
    return "Pick a project or a property, not both" if project_id.present? && property_id.present?
    if project_id.blank? && property_id.blank?
      return "Pick a project or property for this form" if active?
    else
      listing = listing_unusable_message
      return listing if listing
    end
    return "Map Name and Mobile" if explicit_mappings? && !name_and_mobile_mapped?

    nil
  end

  def ready_for_import?
    ready_for_import_error.nil?
  end

  def ready_for_import_error
    return "Form is turned off" unless active?
    return "Pick a project or property for this form" if project_id.blank? && property_id.blank?

    listing_error = listing_unusable_message
    return listing_error if listing_error
    return "Map Name and Mobile" if explicit_mappings? && !name_and_mobile_mapped?

    nil
  end

  def listing_name
    project&.name || property&.title
  end

  private

  def name_and_mobile_mapped?
    Facebook::FieldMapper.covers_name?(field_mappings) &&
      Facebook::FieldMapper.covers_mobile?(field_mappings)
  end

  def listing_unusable_message
    if project_id.present?
      return "Pick a project or property for this form" if foreign_project?
      return listing_message(project&.name || "This project") unless usable_project?
    elsif property_id.present?
      return "Pick a project or property for this form" if foreign_property?
      return listing_message(property&.title || "This property") unless usable_property?
    end
    nil
  end

  def foreign_project?
    project.present? && !project.marketplace? && project.firm_id != firm_id
  end

  def foreign_property?
    property.present? && property.firm_id != firm_id
  end

  def usable_project?
    return false if project.nil?

    own = project.firm_id == firm_id && project.from_own? && project.active?
    shared = project.marketplace? && project.active?
    own || shared
  end

  def usable_property?
    property.present? && property.firm_id == firm_id && property.available?
  end

  def listing_message(name)
    "#{name} is no longer active — pick another listing"
  end

  def form_id_is_globally_unique
    return if form_id.blank?

    scope = self.class.across_firms.where(form_id:)
    scope = scope.where.not(id:) if persisted?
    errors.add(:form_id, "has already been taken") if scope.exists?
  end

  def one_listing
    return unless project_id.present? && property_id.present?

    errors.add(:base, "Pick a project or a property, not both")
  end

  # Only a change is checked. A source turned off later must not block a
  # sync or any other save that leaves the choice as it is.
  def lead_source_is_active
    return if lead_source_id.blank?
    return if lead_source&.active?

    errors.add(:base, "The chosen lead source is turned off")
  end
end
