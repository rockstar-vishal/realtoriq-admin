# frozen_string_literal: true

# One firm's footer on one catalog creative. A new fingerprint replaces the
# previous file for that pair.
class PersonalisedCreative < ApplicationRecord
  include FirmScoped

  belongs_to :project_creative
  has_one_attached :file

  validates :fingerprint, presence: true
end
