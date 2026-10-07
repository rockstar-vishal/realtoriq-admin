# frozen_string_literal: true

# A broker's signed-in device.
class AuthSession < ApplicationRecord
  include FirmScoped

  REFRESH_TTL = 60.days

  # Unscoped for the same reason as OneTimeCode#user: the session is resolved
  # from a token *in order to* establish the tenant, so Current.firm is still
  # nil at that point.
  belongs_to :user, -> { unscope(where: :firm_id) }
  has_many :push_subscriptions, -> { unscope(where: :firm_id) }, dependent: :delete_all

  scope :live, -> { where(revoked_at: nil).where(expires_at: Time.current..) }
  scope :oldest_first, -> { order(:last_used_at, :created_at) }

  def self.digest(token) = Digest::SHA256.hexdigest(token.to_s)

  # Returns [session, refresh_token]. The refresh token is shown once; only its
  # digest is stored, so a database leak can't be used to mint access tokens.
  def self.start!(user:, device: {}, ip: nil, user_agent: nil)
    refresh_token = SecureRandom.urlsafe_base64(48)
    device_id = device[:device_id].presence

    transaction do
      # Reinstalling the app on a known device should reclaim its slot rather
      # than consume another one. `live` excludes expired rows, but the unique
      # index does not — an idle-expired session with revoked_at still null
      # occupies the slot and the next sign-in on that device 500s.
      if device_id
        user.auth_sessions.where(device_id:, revoked_at: nil).find_each do |s|
          s.revoke!("replaced_by_same_device")
        end
      end

      evict_over_limit(user)

      session = user.auth_sessions.create!(
        firm_id: user.firm_id,
        refresh_token_digest: digest(refresh_token),
        device_id:,
        device_name: device[:device_name],
        platform: device[:platform],
        app_version: device[:app_version],
        ip:,
        user_agent:,
        last_used_at: Time.current,
        expires_at: REFRESH_TTL.from_now
      )

      [ session, refresh_token ]
    end
  end

  # The design has a "device limit reached" state, but blocking sign-in on a
  # phone someone just bought is a support ticket, not a security win — so the
  # oldest session is evicted instead and the newest device always gets in.
  def self.evict_over_limit(user)
    limit = user.firm.device_limit
    live_sessions = user.auth_sessions.live.oldest_first.to_a

    surplus = live_sessions.size - (limit - 1)
    return if surplus <= 0

    live_sessions.first(surplus).each { |s| s.revoke!("device_limit") }
  end

  def active? = revoked_at.nil? && expires_at.future?

  # Revoke drops push subscriptions too. Sign-in on the same device replaces
  # this row, and a revoked session must not keep receiving reminders. Current
  # firm is often unset here (sign-in, device-limit eviction), so the delete
  # is explicit and unscoped. Refresh does not revoke, so it keeps the row.
  def revoke!(reason = "signed_out")
    transaction do
      PushSubscription.across_firms.where(auth_session_id: id).delete_all
      update!(revoked_at: Time.current, revoked_reason: reason)
    end
  end

  # Returns a new refresh token, or nil when this row no longer matches the
  # digest the caller presented — another request already rotated it. Callers
  # must treat nil as a replay (401), not issue a second pair.
  def rotate_if_matches!(presented_digest)
    token = nil
    AuthSession.across_firms.transaction do
      locked = AuthSession.across_firms.lock.find_by(id:)
      if locked&.active? &&
          ActiveSupport::SecurityUtils.secure_compare(locked.refresh_token_digest, presented_digest)
        token = locked.rotate_refresh_token!
      end
    end
    token
  end

  # Refresh tokens rotate on every use: a stolen token is good for one call, and
  # its use invalidates the copy the real device holds — which surfaces the theft
  # rather than hiding it.
  def rotate_refresh_token!
    token = SecureRandom.urlsafe_base64(48)
    update!(refresh_token_digest: self.class.digest(token),
            last_used_at: Time.current,
            expires_at: REFRESH_TTL.from_now)
    token
  end

  def touch_used!
    return if last_used_at.present? && last_used_at > 5.minutes.ago

    update_column(:last_used_at, Time.current)
  end
end
