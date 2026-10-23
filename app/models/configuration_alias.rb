# frozen_string_literal: true

# A name we have already decided, so the next import does not ask again.
# Global, like the configuration it points at.
class ConfigurationAlias < ApplicationRecord
  SOURCES = %w[merge review seed].freeze

  belongs_to :typology
  belongs_to :created_by_admin, class_name: "AdminUser", optional: true

  validates :key, presence: true, uniqueness: true
  validates :source, inclusion: { in: SOURCES }
end
