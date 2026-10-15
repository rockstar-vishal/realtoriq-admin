# frozen_string_literal: true

# Public registration. A firm exists only after Submit. Until then the only
# state is the verify cookie and one-time codes.
module Onboarding
  ACCEPTANCE_STATEMENT = "I confirm that I am authorised to act for this firm, that the details I have given are true and complete, and that I have read and accept the RealtorIQ Terms & Conditions and Privacy Policy."
  RERA_DECLARATION = "I do not hold a RERA agent registration. I confirm that the business I will conduct through RealtorIQ does not require one, and that I will not facilitate the sale or purchase of any plot, apartment or building in a RERA-registered project until I hold a valid registration."

  ENTITY_TYPES = %w[individual proprietorship partnership llp private_limited public_limited other].freeze
  # humanize turns "llp" into "Llp" and "private_limited" into "Private limited".
  ENTITY_TYPE_LABELS = {
    "individual" => "Individual",
    "proprietorship" => "Proprietorship",
    "partnership" => "Partnership",
    "llp" => "LLP",
    "private_limited" => "Private Limited",
    "public_limited" => "Public Limited",
    "other" => "Other"
  }.freeze
  # String keys on purpose: the Ruby symbol :2_5 is the float 2.5.
  TEAM_SIZES = %w[just_me 2_5 6_20 21_plus].freeze
  # humanize turns "2_5" into "2 5", which is not a team size a broker can read.
  TEAM_SIZE_LABELS = {
    "just_me" => "Just me",
    "2_5" => "2–5",
    "6_20" => "6–20",
    "21_plus" => "21+"
  }.freeze
  FILE_TYPES = %w[application/pdf image/jpeg image/png image/webp image/heic image/heif].freeze
  MAX_FILE_BYTES = 2.megabytes
  MAX_SUBMIT_BYTES = 5.megabytes
  REFERENCE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTVWXYZ"

  REGISTERED_NUMBER = "This number is already registered on RealtorIQ. Sign in at https://app.realtoriq.kgen.tech."
  REGISTERED_EMAIL = "This email is already registered on RealtorIQ. Sign in at https://app.realtoriq.kgen.tech."
  UNDER_REVIEW_NUMBER = "An application with this number is already under review."
  UNDER_REVIEW_EMAIL = "An application with this email is already under review."
  BUSY = "Verification is busy right now. Please try again in a little while."
  TOO_MANY = "Too many attempts. Try again later."
  WAIT = "Wait a moment before sending another code."
  DELIVERY_FAILED = "Couldn't send the code right now. Try again shortly."
  VERIFY_AGAIN = "Verify this again"
  ALREADY_VERIFIED = "This is already verified."
  UNAPPROVED = "Your firm isn't approved yet. We'll email you when the workspace is ready."
  NOT_REGISTERED = "This number isn't registered. Register your firm at https://api.realtoriq.kgen.tech/self-signup"
  PLAN_REQUIRED = "Assign a current plan on the Subscription tab before activating."
  DISCARDED_FIRM = "This firm can no longer be activated."
  REGISTER_URL = "https://api.realtoriq.kgen.tech/self-signup"
  SIGN_IN_URL = "https://app.realtoriq.kgen.tech"

  def self.entity_label(kind)
    ENTITY_TYPE_LABELS[kind.to_s] || kind.to_s.humanize
  end

  INDIAN_MOBILE = /\A\+91[6-9]\d{9}\z/
  PAN_FORMAT = /\A[A-Z]{5}\d{4}[A-Z]\z/
  GSTIN_FORMAT = /\A\d{2}[A-Z]{5}\d{4}[A-Z][1-9A-Z]Z[0-9A-Z]\z/
  RERA_FORMAT = %r{\A[A-Za-z0-9/\-]{5,40}\z}
end
