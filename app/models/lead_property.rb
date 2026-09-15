# frozen_string_literal: true

# A resale or rental listing this lead is considering. Same rules as
# LeadProject: many mappings, kept after a booking, not required to book.
class LeadProperty < ApplicationRecord
  include FirmScoped

  belongs_to :lead, -> { unscope(where: :firm_id) }
  belongs_to :property, -> { unscope(where: :firm_id) }

  belongs_to_same_firm :lead, :property

  validates :property_id, uniqueness: { scope: :lead_id }
end
