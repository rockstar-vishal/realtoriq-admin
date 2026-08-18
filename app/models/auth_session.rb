# frozen_string_literal: true

# A broker's signed-in device.
class AuthSession < ApplicationRecord
  include FirmScoped

  REFRESH_TTL = 60.days

  # Unscoped for the same reason as OneTimeCode#user: the session is resolved
  # from a token *in order to* establish the tenant, so Current.firm is still
  # nil at that point.
  belongs_to :user, -> { unscope(where: :firm_id) }

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
      # than consume another one.
      user.auth_sessions.live.where(device_id:).find_each { |s| s.revoke!("replaced_by_same_device") } if device_id

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

  def revoke!(reason = "signed_out")
    update!(revoked_at: Time.current, revoked_reason: reason)
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
