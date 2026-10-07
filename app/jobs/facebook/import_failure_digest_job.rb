# frozen_string_literal: true

module Facebook
  # Finds firms with dead imports waiting for a notice, and hands each firm
  # to its own job. A burst waits 90 seconds, or 10 minutes at the longest,
  # then stays quiet for 6 hours.
  class ImportFailureDigestJob < ApplicationJob
    def perform
      firm_ids = FacebookLeadImport.across_firms.where.not(failure_alert_pending_at: nil).distinct.pluck(:firm_id)
      firm_ids.each { |firm_id| ImportFailureDigestFirmJob.perform_later(firm_id) }
    end
  end

  class ImportFailureDigestFirmJob < TenantJob
    class DeliveryFailed < StandardError; end

    QUIET_FOR = 90.seconds
    BURST_CAP = 10.minutes
    COOLDOWN = 6.hours

    retry_on DeliveryFailed, wait: :polynomially_longer, attempts: 5

    def perform(firm_id)
      state = FacebookImportAlertState.for_firm!(firm_id)
      claimed_at = nil
      previous = nil
      import_ids = []

      state.with_lock do
        pending = FacebookLeadImport.where.not(failure_alert_pending_at: nil)
        return if pending.none?

        newest = pending.maximum(:failure_alert_pending_at)
        oldest = pending.minimum(:failure_alert_pending_at)
        return unless quiet?(newest, oldest)
        return if cooling_down?(state)

        previous = state.last_failure_emailed_at
        claimed_at = Time.current
        return if claim(state, previous, claimed_at).zero?

        import_ids = pending.pluck(:id)
      end

      imports = FacebookLeadImport.where(id: import_ids).order(:id).to_a
      if imports.empty?
        revert(state, claimed_at, previous)
        return
      end

      begin
        notify(imports, claimed_at)
      rescue DeliveryFailed
        revert(state, claimed_at, previous)
        raise
      end

      deliver_emails(imports)

      communicated_at = Time.current
      FacebookLeadImport.where(id: imports.map(&:id)).update_all(
        failure_alert_pending_at: nil,
        failure_alerted_at: communicated_at,
        updated_at: communicated_at
      )
    end

    private

    def quiet?(newest, oldest)
      return false if newest.blank? || oldest.blank?

      newest <= QUIET_FOR.ago || oldest <= BURST_CAP.ago
    end

    def cooling_down?(state)
      state.last_failure_emailed_at.present? && state.last_failure_emailed_at > COOLDOWN.ago
    end

    def claim(state, previous, claimed_at)
      FacebookImportAlertState.where(id: state.id, last_failure_emailed_at: previous).update_all(
        last_failure_emailed_at: claimed_at,
        updated_at: claimed_at
      )
    end

    def revert(state, claimed_at, previous)
      FacebookImportAlertState.where(id: state.id, last_failure_emailed_at: claimed_at).update_all(
        last_failure_emailed_at: previous,
        updated_at: Time.current
      )
    end

    def notify(imports, claimed_at)
      reasons = FacebookAlertMailer.reason_summary(imports)
      top = reasons.first
      body = "#{imports.size} Facebook #{"lead".pluralize(imports.size)} could not be imported."
      body = "#{body} #{top[:message]}" if top
      firm_id = imports.first.firm_id
      User.where(role: "super_admin", status: "active").find_each do |user|
        Notifications::Record.call(
          user:,
          kind: "facebook",
          title: "Facebook leads need attention",
          body:,
          dedupe_key: "fb_import_fail:#{firm_id}:#{claimed_at.to_i}",
          data: { "page" => "settings", "item" => "facebook" },
          force: true
        )
      end
    rescue StandardError => e
      Log.error("import_digest_notify", error_class: e.class.name)
      raise DeliveryFailed
    end

    def deliver_emails(imports)
      User.where(role: "super_admin", status: "active").find_each do |user|
        next if user.email.blank?

        FacebookAlertMailer.lead_import_failures(user:, imports:).deliver_now
      rescue StandardError => e
        Log.error("import_digest_email", error_class: e.class.name)
      end
    end
  end
end
