# frozen_string_literal: true

# The token on a turbo microsite link. It resolves the firm and the broker.
# The project is the global catalog row, so it is not same-firm as the link.
class ProjectShareLink < ApplicationRecord
  include FirmScoped

  belongs_to :user, -> { unscope(where: :firm_id) }
  belongs_to :project, -> { unscope(where: :firm_id) }

  belongs_to_same_firm :user

  validates :token, presence: true, uniqueness: true
  validate :project_is_marketplace

  before_validation :assign_token, on: :create

  private

  def assign_token
    self.token ||= SecureRandom.urlsafe_base64(32)
  end

  def project_is_marketplace
    return if project&.marketplace?

    errors.add(:project, "is not a marketplace project")
  end
end
