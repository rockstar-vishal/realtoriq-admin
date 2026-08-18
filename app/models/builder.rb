# frozen_string_literal: true

# A developer. Two kinds live in this table:
#
#   firm_id NULL — the platform's curated list, maintained by ops, seen by all
#   firm_id set  — one a broker added inline from the project form
#
# Deliberately NOT FirmScoped. The fail-closed default scope resolves to
# `firm_id IS NULL`, which would hide every firm-owned builder — and the global
# rows every firm is meant to see are exactly the ones a tenant scope would cut
# out. Visibility is therefore explicit: use `available_to`.
class Builder < ApplicationRecord
  belongs_to :firm, optional: true

  has_one_attached :logo
  has_many :projects, dependent: :restrict_with_error

  validates :name, presence: true
  validates :slug, presence: true
  validate :name_is_unique_within_its_scope

  before_validation :assign_slug

  scope :active, -> { where(active: true) }
  scope :alphabetical, -> { order(:name) }
  scope :global, -> { where(firm_id: nil) }

  # The list a firm may pick from: everyone's, plus its own.
  scope :available_to, ->(firm) { where(firm_id: [ nil, firm&.id ].uniq) }

  def global? = firm_id.nil?

  # Ids rather than slugs: two firms can hold the same slug now, so a slug no
  # longer identifies one row.
  def to_param = id

  private

  def assign_slug
    self.slug = slug.presence || name.to_s.parameterize
  end

  # Uniqueness has two halves because the database enforces it with two partial
  # indexes — Postgres treats NULLs as distinct, so one scoped validation would
  # let the global list hold the same name twice.
  def name_is_unique_within_its_scope
    return if name.blank?

    scope = self.class.where(firm_id:).where("LOWER(name) = ?", name.to_s.downcase)
    scope = scope.where.not(id:) if id.present?

    errors.add(:name, "has already been taken") if scope.exists?
  end
end
