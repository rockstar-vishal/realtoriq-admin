# frozen_string_literal: true

# A fixed one-time code turns sign-in into "know a mobile number, become that
# broker". It exists so testing doesn't mean grepping a log for six digits, and
# it must never survive to production. Development and staging may use one;
# production may not, and refuses to boot rather than warn.
#
# The check is a failed boot rather than a warning: a warning scrolls past in a
# deploy log, and the failure mode here is silent and total.
fixed_code = Rails.configuration.x.otp_fixed_code

if fixed_code.present?
  if Rails.env.production?
    raise <<~ABORT
      Refusing to boot: one-time codes are pinned to a fixed value in production.

      OTP_FIXED_CODE is set, which lets anyone sign in as any broker whose mobile
      number they know. Unset it and let codes be generated normally.
    ABORT
  end

  # Six, matching OneTimeCode::CODE_LENGTH — written as a literal because
  # initializers run before autoloading, so naming the model here would break
  # boot entirely. A spec asserts the two stay in step.
  unless fixed_code.to_s.match?(/\A\d{6}\z/)
    raise "OTP_FIXED_CODE must be exactly 6 digits, got #{fixed_code.inspect}"
  end

  # Deliberately loud, and repeated at every boot: on a reachable staging box
  # this is the difference between a demo environment and an open door.
  Rails.logger.warn(
    "[otp] Sign-in codes are FIXED at #{fixed_code} (#{Rails.env}). " \
    "Nothing is delivered. Anyone who knows a registered mobile can sign in " \
    "as that broker — keep this host off the public internet."
  )
end
