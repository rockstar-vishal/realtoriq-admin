# frozen_string_literal: true

# Join for the design's multi-select "Preferred configuration".
#
# Not FirmScoped: it carries no firm_id and is only ever reached through a lead,
# which is scoped. Adding one would mean a redundant column to keep in step.
class LeadTypology < ApplicationRecord
  belongs_to :lead
  belongs_to :typology

  validates :typology_id, uniqueness: { scope: :lead_id }
  validate :configuration_matches_lead_category

  private

  def configuration_matches_lead_category
    return if typology.nil? || lead.nil? || typology.category == lead.category

    errors.add(:base, "Configurations must all be #{lead.category_label}")
  end
end
