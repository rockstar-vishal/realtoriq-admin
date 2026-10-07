# frozen_string_literal: true

module Facebook
  # Fetches one lead and imports it. claim! makes a second worker a no-op.
  class ProcessLeadJob < TenantJob
    WAITS = { 1 => 1.minute, 2 => 5.minutes, 3 => 15.minutes, 4 => 60.minutes }.freeze

    def perform(_firm_id, import_id)
      import = FacebookLeadImport.find_by(id: import_id)
      return if import.nil? || terminal?(import)
      return unless import.claim!

      process(import)
    rescue StandardError => e
      Log.error("process_lead", import_id:, error_class: e.class.name)
      recover(import)
    end

    private

    def process(import)
      started_at = import.processing_started_at
      page = import.facebook_page
      connection = page.facebook_connection
      unless page.page_active? && page.subscribed? && connection&.connection_active?
        message = if page.page_error?
          TokenManager::PAGE_MESSAGE
        else
          "Page not subscribed or Facebook disconnected"
        end
        import.mark_dead_permanent!(message:, alert: !page.page_error?)
        return
      end

      payload = fetch_payload(import, page, connection, started_at)
      return if payload.nil?
      return unless still_claimed?(import, started_at)

      import.update!(fetched_payload: stringify(payload))
      form = resolve_form(import, payload)
      if form.nil?
        import.mark_dead_permanent!(message: "Lead form could not be resolved", alert: true)
        return
      end
      import.update!(facebook_lead_form: form) if import.facebook_lead_form_id != form.id

      unless form.active?
        import.mark_skipped!(message: "Form is turned off")
        return
      end

      if (message = form.ready_for_import_error)
        import.mark_dead_permanent!(message:, alert: true)
        return
      end

      result = LeadImporter.call(import:, form:, payload:)
      finish(import, form, result)
    end

    def fetch_payload(import, page, connection, started_at)
      GraphApiClient.new(access_token: page.page_access_token).fetch_lead(import.leadgen_id)
    rescue Errors::TokenInvalidError => e
      return nil unless still_claimed?(import, started_at)

      TokenManager.handle_api_error(connection, e, page:)
      import.mark_dead_permanent!(message: TokenManager::PAGE_MESSAGE, alert: false)
      nil
    rescue Errors::RateLimitError
      return nil unless still_claimed?(import, started_at)

      transient(import, "Facebook is busy. We'll try again.")
      nil
    rescue Errors::LeadFetchError
      return nil unless still_claimed?(import, started_at)

      transient(import, "Could not fetch this lead")
      nil
    rescue ActiveRecord::Encryption::Errors::Decryption
      return nil unless still_claimed?(import, started_at)

      import.mark_dead_permanent!(message: "Could not read the Page token", alert: true)
      nil
    end

    # The sweeper may have handed this import to a newer worker while the
    # Graph call was in flight. The newer worker owns the row.
    def still_claimed?(import, started_at)
      import.reload
      import.processing? && import.processing_started_at&.to_i == started_at&.to_i
    end

    def finish(import, form, result)
      case result.status
      when :created
        safe_notify { Notify.lead_created(lead: result.lead, form:, leadgen_id: import.leadgen_id) }
      when :duplicate
        safe_notify { Notify.duplicate(firm: import.firm, lead: result.lead, leadgen_id: import.leadgen_id) }
      else
        import.mark_dead_permanent!(message: result.error.presence || "We could not save this lead.", alert: true)
      end
    end

    def resolve_form(import, payload)
      return import.facebook_lead_form if import.facebook_lead_form_id.present?

      form_id = payload["form_id"].to_s.presence
      return nil if form_id.blank?

      existing = FacebookLeadForm.across_firms.find_by(form_id:)
      return existing if existing&.firm_id == import.firm_id
      return nil if existing

      FacebookLeadForm.create!(
        firm: import.firm,
        facebook_page: import.facebook_page,
        form_id:,
        form_name: "Form #{form_id}",
        active: true
      )
    rescue ActiveRecord::RecordNotUnique
      owned = FacebookLeadForm.across_firms.find_by(form_id: payload["form_id"].to_s)
      owned if owned&.firm_id == import.firm_id
    end

    def transient(import, message)
      became_dead = import.record_failure!(message:)
      if became_dead
        import.update!(failure_alert_pending_at: Time.current, next_attempt_at: nil)
        return
      end

      wait = WAITS.fetch(import.retry_count, 60.minutes)
      import.update!(next_attempt_at: Time.current + wait)
      self.class.set(wait:).perform_later(import.firm_id, import.id)
    end

    def recover(import)
      return if import.nil?

      import.reload
      return if terminal?(import)

      transient(import, "Could not import this lead")
    rescue StandardError => e
      Log.error("process_lead_recover", import_id: import.id, error_class: e.class.name)
    end

    def safe_notify
      yield
    rescue StandardError => e
      Log.error("process_lead_notify", error_class: e.class.name)
    end

    def terminal?(import)
      import.created? || import.duplicate? || import.dead?
    end

    def stringify(payload)
      JSON.parse(payload.to_json)
    rescue JSON::ParserError, TypeError
      {}
    end
  end
end
