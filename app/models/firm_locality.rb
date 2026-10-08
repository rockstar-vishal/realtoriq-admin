# frozen_string_literal: true

# A locality the firm works in besides the primary pin on `firms.locality_id`.
# The primary is not stored here. Ops replaces the set from the firm form.
class FirmLocality < ApplicationRecord
  include FirmScoped

  belongs_to :locality

  validates :locality_id, uniqueness: { scope: :firm_id }
end
