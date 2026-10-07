# frozen_string_literal: true

# A project this lead is considering. Many are allowed; closing one (a booking)
# does not remove the others — they stay as history. Booking does not require
# a row here: a broker can book a project they never mapped.
class LeadProject < ApplicationRecord
  include FirmScoped

  belongs_to :lead, -> { unscope(where: :firm_id) }
  belongs_to :project, -> { unscope(where: :firm_id) }

  belongs_to_same_firm :lead, :project, allow_marketplace: true
  validate :sale_lead_only

  validates :project_id, uniqueness: { scope: :lead_id }

  private

  def sale_lead_only
    return if lead.blank? || lead.sale?

    errors.add(:base, "A rental lead cannot be mapped to a project")
  end
end
