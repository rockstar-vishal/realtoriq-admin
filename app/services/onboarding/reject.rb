# frozen_string_literal: true

module Onboarding
  class Reject
    def self.call(application:, admin:, reason:)
      return false if reason.to_s.strip.blank?
      return false unless Discard.call(application:, status: "rejected", admin:, reason: reason.to_s.strip)

      firm = Firm.find_by(id: application.firm_id)
      AuditEvent.record!(
        subject: application, action: "onboarding.rejected", actor: admin, firm:,
        metadata: { reason: reason.to_s.strip }
      )
      OnboardingMailer.rejected(application.id).deliver_later
      true
    end
  end
end
