# frozen_string_literal: true

# A mapped property included in one outing. Unmapping the lead does not remove
# this row, so the property page can still show that the client came.
class LeadVisitProperty < ApplicationRecord
  include FirmScoped

  belongs_to :lead_visit, -> { unscope(where: :firm_id) }
  belongs_to :property, -> { unscope(where: :firm_id) }
  belongs_to_same_firm :lead_visit
  validate :property_is_visitable

  validates :property_id, uniqueness: { scope: :lead_visit_id }

  private

  # A shared listing can be visited once this firm has mapped it. The visit
  # stays on this firm's lead. The listing firm's visitor list does not see it.
  def property_is_visitable
    return if property.blank? || firm_id.blank? || property.firm_id == firm_id

    mapped = LeadProperty.unscoped.exists?(
      lead_id: lead_visit&.lead_id, property_id: property.id, firm_id: firm_id
    )
    return if mapped

    errors.add(:property_id, "isn't one of this firm's records")
  end
end
