# frozen_string_literal: true

# One key per firm. The digest is what a website's request is looked up by.
# The token itself stays encrypted so the owner can copy it again later.
class InboundCredential < ApplicationRecord
  include FirmScoped

  encrypts :token

  validates :token, :token_digest, presence: true
  validates :firm_id, uniqueness: true

  def self.authenticate(raw)
    return if raw.blank?

    record = across_firms.find_by(token_digest: Digest::SHA256.hexdigest(raw))
    return if record.nil? || !record.firm&.active?

    record
  end

  def self.ensure_for!(firm)
    across_firms.find_by(firm_id: firm.id) || issue!(firm)
  end

  def self.issue!(firm)
    raw = SecureRandom.urlsafe_base64(32)
    create!(firm:, token: raw, token_digest: Digest::SHA256.hexdigest(raw))
  rescue ActiveRecord::RecordNotUnique
    across_firms.find_by!(firm_id: firm.id)
  end

  def rotate!(actor:)
    raw = SecureRandom.urlsafe_base64(32)
    update!(token: raw, token_digest: Digest::SHA256.hexdigest(raw))
    AuditEvent.record!(subject: self, action: "inbound_credential.rotate", actor:, firm:)
    self
  end
end
