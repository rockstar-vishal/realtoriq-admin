# frozen_string_literal: true

# One edge of the firm's reporting graph: `manager` is a boss of `user`.
# Several bosses per person are allowed. Superadmins do not appear here.
class UserManager < ApplicationRecord
  include FirmScoped

  belongs_to :user, -> { unscope(where: :firm_id) }
  belongs_to :manager, -> { unscope(where: :firm_id) }, class_name: "User"

  belongs_to_same_firm :user, :manager

  validates :user_id, uniqueness: { scope: :manager_id }
  validate :not_self
  validate :participants_are_not_super_admins
  validate :no_reporting_cycle

  private

  def not_self
    return if user_id.blank? || manager_id.blank? || user_id != manager_id

    errors.add(:manager_id, "can't be the same person")
  end

  # Superadmins see the whole firm by default, so they are not stored here.
  # Putting one on either end of an edge makes the graph lie about access.
  def participants_are_not_super_admins
    errors.add(:user_id, "the super admin is not part of the reporting graph") if user&.super_admin?
    errors.add(:manager_id, "the super admin is not part of the reporting graph") if manager&.super_admin?
  end

  # Adding "A manages B" is a cycle when A already sits in B's line (B, or
  # anyone B already manages). The recursive read is cycle-safe on its own;
  # this check stops the row that would close a loop from being stored.
  def no_reporting_cycle
    return if user_id.blank? || manager_id.blank? || user_id == manager_id
    return if user.nil?

    descendant_ids = User.manageable_ids_for(user)
    return unless descendant_ids.include?(manager_id.to_s)

    errors.add(:manager_id, :reporting_cycle, message: "would create a reporting cycle")
  end
end
