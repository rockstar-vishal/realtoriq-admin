# frozen_string_literal: true

# One configuration a project offers, with where its pricing starts.
#
# The design notes these numbers "drive lead matchmaking" — matching itself is a
# later slice, but this is the data it will read.
class ProjectTypology < ApplicationRecord
  belongs_to :project, -> { unscope(where: :firm_id) }
  belongs_to :typology

  validates :typology_id, uniqueness: { scope: :project_id }
  validates :starting_price,
    numericality: { greater_than: 0, only_integer: true }, allow_nil: true
  validates :starting_carpet_sqft,
    numericality: { greater_than: 0, only_integer: true }, allow_nil: true

  # ₹ per sqft, which is how brokers compare configurations against each other.
  def rate_per_sqft
    return nil if starting_price.blank? || starting_carpet_sqft.to_i.zero?

    (starting_price.to_d / starting_carpet_sqft).round
  end
end
