# frozen_string_literal: true

# The Facebook login that one browser started. The callback stores the
# result here. Only that browser, still signed in as the same user, can
# turn it into a connection. A wrong confirm voids it.
class FacebookOauthAttempt < ApplicationRecord
  include FirmScoped

  STATUSES = %w[started completed failed consumed].freeze

  enum :status, STATUSES.index_by(&:itself), validate: true, default: :started

  encrypts :result

  belongs_to :user, -> { unscope(where: :firm_id) }
  belongs_to_same_firm :user

  validates :nonce_digest, :expires_at, presence: true

  def self.dump_oauth_result(oauth_result)
    {
      "long_lived_token" => oauth_result[:long_lived_token],
      "expires_at" => oauth_result[:expires_at]&.iso8601,
      "fb_user_id" => oauth_result[:fb_user_id],
      "fb_user_name" => oauth_result[:fb_user_name],
      "client_business_id" => oauth_result[:client_business_id],
      "token_kind" => oauth_result[:token_kind],
      "pages" => Array(oauth_result[:pages]).map { |page| dump_page(page) }
    }.to_json
  end

  def self.dump_page(page)
    page = page.with_indifferent_access
    {
      "page_id" => page[:page_id].to_s,
      "page_name" => page[:page_name].to_s,
      "page_access_token" => page[:page_access_token]
    }
  end

  def oauth_result
    return if result.blank?

    data = JSON.parse(result)
    {
      long_lived_token: data["long_lived_token"],
      expires_at: data["expires_at"].present? ? Time.zone.parse(data["expires_at"]) : nil,
      fb_user_id: data["fb_user_id"],
      fb_user_name: data["fb_user_name"],
      client_business_id: data["client_business_id"],
      token_kind: data["token_kind"],
      pages: Array(data["pages"]).map { |page| self.class.restore_page(page) }
    }
  end

  def self.restore_page(page)
    page = page.with_indifferent_access
    {
      page_id: page[:page_id].to_s,
      page_name: page[:page_name],
      page_access_token: page[:page_access_token]
    }
  end

  def expired?
    expires_at <= Time.current
  end

  # The raw ticket never lands in the database. Lookup is by its digest, then
  # a length-checked compare, the same way a confirm checks the nonce.
  def self.usable_handoff(ticket)
    digest = Digest::SHA256.hexdigest(ticket.to_s)
    attempt = across_firms.find_by(handoff_ticket_digest: digest)
    return unless ticket_digest_matches?(attempt, digest)
    return unless handoff_open?(attempt)

    attempt
  end

  def self.claim_handoff!(attempt)
    claimed = across_firms.where(id: attempt.id, handoff: true, status: "started", handoff_used_at: nil)
      .where("expires_at > ?", Time.current)
      .where("handoff_expires_at > ?", Time.current)
      .update_all(handoff_used_at: Time.current, updated_at: Time.current)
    claimed == 1
  end

  def self.ticket_digest_matches?(attempt, digest)
    return false if attempt.nil?

    stored = attempt.handoff_ticket_digest.to_s
    return false if stored.blank? || digest.bytesize != stored.bytesize

    ActiveSupport::SecurityUtils.secure_compare(digest, stored)
  end
  private_class_method :ticket_digest_matches?

  def self.handoff_open?(attempt)
    attempt.handoff? && attempt.started? && !attempt.expired? &&
      attempt.handoff_used_at.nil? && attempt.handoff_expires_at.present? &&
      attempt.handoff_expires_at > Time.current
  end
  private_class_method :handoff_open?

  def void!(error_code:)
    update!(status: :failed, error_code:, result: nil)
  end
end
