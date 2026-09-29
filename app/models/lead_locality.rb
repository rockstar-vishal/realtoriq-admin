# frozen_string_literal: true

# Preferred localities on a lead. Many are allowed.
#
# Not FirmScoped: it carries no firm_id and is only ever reached through a lead,
# which is scoped. Adding one would mean a redundant column to keep in step.
class LeadLocality < ApplicationRecord
  belongs_to :lead
  belongs_to :locality

  validates :locality_id, uniqueness: { scope: :lead_id }
end
