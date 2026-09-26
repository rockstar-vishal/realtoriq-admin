# frozen_string_literal: true

# A mapped project included in one outing. Unmapping the lead does not remove
# this row, so the project page can still show that the client came.
class LeadVisitProject < ApplicationRecord
  include FirmScoped

  belongs_to :lead_visit, -> { unscope(where: :firm_id) }
  belongs_to :project, -> { unscope(where: :firm_id) }
  belongs_to_same_firm :lead_visit, :project

  validates :project_id, uniqueness: { scope: :lead_visit_id }
end
