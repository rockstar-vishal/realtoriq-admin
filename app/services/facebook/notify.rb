# frozen_string_literal: true

module Facebook
  # In-app notices for a saved Facebook lead. Email digests are a separate job.
  class Notify
    def self.lead_created(lead:, form:, leadgen_id:)
      new.lead_created(lead:, form:, leadgen_id:)
    end

    def self.duplicate(firm:, lead:, leadgen_id:)
      new.duplicate(firm:, lead:, leadgen_id:)
    end

    def lead_created(lead:, form:, leadgen_id:)
      recipients(lead).each do |user|
        Notifications::Record.call(
          user:,
          kind: "facebook",
          title: "New Facebook lead",
          body: lead_body(lead, form),
          dedupe_key: "fb_lead:#{leadgen_id}",
          data: { "page" => "leads", "item" => lead.id }
        )
      end
    end

    def duplicate(firm:, lead:, leadgen_id:)
      return if lead.nil?

      state = FacebookImportAlertState.for_firm!(firm)
      stamp = nil
      state.with_lock do
        recent = state.last_duplicate_notified_at && state.last_duplicate_notified_at > 6.hours.ago
        next if recent

        stamp = Time.current
        state.update!(last_duplicate_notified_at: stamp)
      end
      return if stamp.nil?

      User.across_firms.where(firm_id: firm.id, role: "super_admin", status: "active").find_each do |user|
        Notifications::Record.call(
          user:,
          kind: "facebook",
          title: "This Facebook lead is already in your pipeline",
          body: "Existing lead #{lead.code}",
          dedupe_key: "fb_duplicate:#{leadgen_id}:#{stamp.to_i}",
          data: { "page" => "settings", "item" => "facebook" }
        )
      end
    end

    private

    def recipients(lead)
      assignee = lead.assigned_user
      return [ assignee ] if assignee&.active?

      User.across_firms.where(firm_id: lead.firm_id, role: "super_admin", status: "active").to_a
    end

    def lead_body(lead, form)
      [ lead.name.presence || lead.mobile, form.listing_name ].compact.join(" · ")
    end
  end
end
