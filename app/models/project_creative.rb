# frozen_string_literal: true

# A creative LaunchIQ pushed for a catalog project. It has no firm: every
# broker personalises the same file with their own details.
class ProjectCreative < ApplicationRecord
  KINDS = %w[image pdf].freeze

  belongs_to :project, -> { unscope(where: :firm_id) }
  has_many :personalised_creatives, -> { unscope(where: :firm_id) }, dependent: :destroy

  has_one_attached :file do |attachable|
    attachable.variant :thumb, resize_to_limit: [ 480, 480 ]
  end

  validates :external_id, presence: true, uniqueness: { scope: :project_id }
  validates :title, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :position, numericality: { only_integer: true }

  def image? = kind == "image"
  def pdf? = kind == "pdf"
end
