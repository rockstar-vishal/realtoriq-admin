# frozen_string_literal: true

module Onboarding
  # One daily pass: lapse unactivated registrations, hard-delete them 30 days
  # later, and drop acceptances whose retain_until has arrived.
  class PurgeJob < ApplicationJob
    queue_as :default

    def perform
      lapse
      hard_delete
      drop_retained
    end

    private

    def lapse
      OnboardingApplication.across_firms.where(status: "submitted").where(submitted_at: ..7.days.ago).find_each do |application|
        firm = Firm.find_by(id: application.firm_id)
        next unless firm&.pending? && !firm.discarded?
        next unless Discard.call(application:, status: "lapsed")

        AuditEvent.record!(subject: application, action: "onboarding.lapsed", firm:)
      end
    end

    def hard_delete
      Firm.where(discarded_at: ..30.days.ago).find_each do |firm|
        application = OnboardingApplication.across_firms.find_by(firm_id: firm.id)
        next if application.nil?

        previous = Current.firm
        begin
          Current.firm = firm
          LegalAcceptance.across_firms.where(onboarding_application_id: application.id).find_each(&:destroy!)
          application.destroy!
          firm.destroy!
        rescue ActiveRecord::InvalidForeignKey, ActiveRecord::DeleteRestrictionError => e
          Rails.logger.error("[onboarding] purge kept firm #{firm.id} (#{e.class})")
        ensure
          Current.firm = previous
        end
      end
    end

    def drop_retained
      LegalAcceptance.across_firms.where(retain_until: ..Date.current).find_each(&:destroy!)
    end
  end
end
