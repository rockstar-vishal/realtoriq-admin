# frozen_string_literal: true

# A mapped property included in one outing. Unmapping the lead does not remove
# this row, so the property page can still show that the client came.
class LeadVisitProperty < ApplicationRecord
  include FirmScoped

  belongs_to :lead_visit, -> { unscope(where: :firm_id) }
  belongs_to :property, -> { unscope(where: :firm_id) }
  belongs_to_same_firm :lead_visit, :property

  validates :property_id, uniqueness: { scope: :lead_visit_id }
end
