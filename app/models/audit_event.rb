# frozen_string_literal: true

# Append-only history of consequential changes. No update or destroy path — if
# a row here can be edited, it isn't evidence of anything.
class AuditEvent < ApplicationRecord
  belongs_to :actor, polymorphic: true, optional: true
  belongs_to :subject, polymorphic: true
  belongs_to :firm, optional: true

  validates :action, presence: true

  scope :recent_first, -> { order(created_at: :desc) }

  # Audit writes must never be the reason a legitimate action fails, so a
  # problem here is logged rather than raised.
  def self.record!(subject:, action:, actor: nil, firm: nil, metadata: {})
    create!(
      subject:,
      action:,
      actor: actor || Current.admin_user || Current.user,
      firm: firm || inferred_firm(subject),
      metadata:,
      ip: Current.request_ip
    )
  rescue StandardError => e
    Rails.logger.error("[audit] failed to record #{action} on #{subject.class}##{subject.id}: #{e.message}")
    nil
  end

  def self.inferred_firm(subject)
    return subject if subject.is_a?(Firm)
    return subject.firm if subject.respond_to?(:firm)

    nil
  end
  private_class_method :inferred_firm

  def readonly?
    persisted?
  end
end
