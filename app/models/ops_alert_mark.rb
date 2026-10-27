# frozen_string_literal: true

# One row per named ops alert. Not firm-scoped: the queue is the whole server.
class OpsAlertMark < ApplicationRecord
  validates :name, presence: true, uniqueness: true

  def self.for!(name)
    find_or_create_by!(name:)
  rescue ActiveRecord::RecordNotUnique
    find_by!(name:)
  end
end
