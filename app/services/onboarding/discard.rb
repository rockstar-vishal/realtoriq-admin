# frozen_string_literal: true

module Onboarding
  # Soft-deletes a registration firm: the application leaves "submitted", the
  # firm's users are destroyed so the mobile and email can be used again, and
  # discarded_at starts the 30-day clock. Activated firms are never discarded.
  class Discard
    def self.call(application:, status:, admin: nil, reason: nil)
      previous = Current.firm
      changed = false

      application.with_lock do
        firm = Firm.find(application.firm_id)
        next unless application.submitted? && firm.pending? && !firm.discarded?

        Current.firm = firm
        firm.contact_channels.update_all(verified_by_user_id: nil)
        OneTimeCode.where(user_id: firm.users.select(:id)).update_all(user_id: nil)
        firm.users.find_each(&:destroy!)
        firm.update!(discarded_at: Time.current)
        attrs = { status: }
        if status.to_s == "rejected"
          attrs[:rejection_reason] = reason
          attrs[:reviewed_at] = Time.current
          attrs[:reviewed_by_admin] = admin
        end
        application.update!(attrs)
        changed = true
      end

      changed
    ensure
      Current.firm = previous
    end
  end
end
