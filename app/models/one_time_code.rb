# frozen_string_literal: true

# A short-lived numeric code, stored only as a bcrypt digest.
#
# Issuing returns the plaintext once, to hand straight to the deliverer. After
# that the code exists nowhere we can read it — not in the database, not in a
# log, not in an exception payload.
class OneTimeCode < ApplicationRecord
  PURPOSES = %w[login verify_email verify_mobile verify_whatsapp].freeze
  CODE_LENGTH = 6
  DEFAULT_TTL = 10.minutes

  enum :purpose, PURPOSES.index_by(&:itself), validate: true

  # Unscoped on purpose. A login code is looked up before anyone is
  # authenticated, so Current.firm is not set — and unlike has_many, a
  # belongs_to does NOT replace the default scope's firm_id condition with the
  # foreign key. Left scoped, this association resolves to nil during sign-in
  # and nobody can ever log in.
  belongs_to :user, -> { unscope(where: :firm_id) }, optional: true
  belongs_to :contact_channel, -> { unscope(where: :firm_id) }, optional: true

  validates :destination, :code_digest, :expires_at, presence: true

  scope :usable, -> { where(consumed_at: nil).where(expires_at: Time.current..) }

  # Returns [record, plaintext_code]. The caller is expected to hand the
  # plaintext to a deliverer and then drop it.
  def self.issue!(purpose:, destination:, user: nil, contact_channel: nil, ttl: DEFAULT_TTL, ip: nil)
    code = generate_code

    record = create!(
      purpose:,
      destination:,
      user:,
      contact_channel:,
      code_digest: BCrypt::Password.create(code),
      expires_at: ttl.from_now,
      request_ip: ip
    )

    [ record, code ]
  end

  # Random unless a fixed code is configured — see config/application.rb and
  # config/initializers/otp_fixed_code.rb, which refuses to boot production with
  # one set. Everything downstream is unchanged: the code is still hashed,
  # still expires, and still burns after its attempts.
  def self.generate_code
    fixed = Rails.configuration.x.otp_fixed_code
    return fixed.to_s if fixed.present?

    SecureRandom.random_number(10**CODE_LENGTH).to_s.rjust(CODE_LENGTH, "0")
  end
  private_class_method :generate_code

  def usable? = consumed_at.nil? && expires_at.future? && attempts < max_attempts

  def expired? = expires_at.past?

  def exhausted? = attempts >= max_attempts

  # Checks a submitted code and consumes the record on success. Returns true
  # only if this exact code was right, unused and in date.
  def verify(submitted)
    return false unless usable?

    if BCrypt::Password.new(code_digest) == submitted.to_s
      update!(consumed_at: Time.current)
      true
    else
      increment!(:attempts)
      false
    end
  end

  # Codes are only useful for a few minutes; anything past its window is noise.
  # Called from a recurring job rather than left to grow forever.
  def self.purge_expired(older_than: 1.day.ago)
    where(expires_at: ...older_than).delete_all
  end
end
