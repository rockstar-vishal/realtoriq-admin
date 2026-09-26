# frozen_string_literal: true

# One browser's Web Push subscription. The endpoint is a capability: anyone
# who has it can deliver a notification, so it is encrypted like a bank account
# number. Deterministic so a later sign-in on the same browser can find and
# reassign the row instead of inserting a duplicate.
class PushSubscription < ApplicationRecord
  include FirmScoped

  encrypts :endpoint, deterministic: true
  encrypts :p256dh
  encrypts :auth_key

  belongs_to :user, -> { unscope(where: :firm_id) }
  belongs_to :auth_session, -> { unscope(where: :firm_id) }
  belongs_to_same_firm :user, :auth_session

  validates :endpoint, :p256dh, :auth_key, presence: true

  # The default scope would hide another firm's row and the unique index would
  # then raise. Callers that reassign an endpoint must look across firms.
  def self.find_by_endpoint(endpoint)
    across_firms.find_by(endpoint:)
  end
end
