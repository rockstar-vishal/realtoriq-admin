# frozen_string_literal: true

# A zip of the microsite for one firm and one catalog project.
class MicrositeKit < ApplicationRecord
  include FirmScoped

  STATUSES = %w[preparing ready failed].freeze
  FAILED_MESSAGE = "Couldn't Prepare the Kit."
  STALE_AFTER = 10.minutes

  belongs_to :project, -> { unscope(where: :firm_id) }
  has_one_attached :file

  validates :fingerprint, presence: true
  validates :status, inclusion: { in: STATUSES }
  validate :project_is_marketplace

  def preparing? = status == "preparing"
  def ready? = status == "ready"
  def failed? = status == "failed"

  private

  def project_is_marketplace
    row = Project.unscoped.find_by(id: project_id)
    return if row&.marketplace?

    errors.add(:project, "is not a marketplace project")
  end
end
