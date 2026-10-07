# frozen_string_literal: true

module Facebook
  # Stores one pending import for a leadgen id and enqueues the worker.
  # A page no firm holds is dropped.
  class RouteLead
    def self.call(value)
      new(value).call
    end

    def initialize(value)
      @value = value.to_h.stringify_keys
    end

    def call
      return if leadgen_id.blank? || page_id.blank?

      firm, page, form = resolve
      return if firm.nil? || page.nil?

      import = nil
      enqueue = false
      Current.set(firm:) do
        import, enqueue = upsert(firm, page, form)
      end
      ProcessLeadJob.perform_later(firm.id, import.id) if enqueue && import
      import
    end

    private

    attr_reader :value

    def leadgen_id = value["leadgen_id"].to_s.presence

    def page_id = value["page_id"].to_s.presence

    def form_id = value["form_id"].to_s.presence

    # A form we already stored names the firm. Otherwise the one firm that
    # has this Page. page_id is unique, so there is never a second row.
    def resolve
      if form_id.present?
        form = FacebookLeadForm.across_firms.find_by(form_id:)
        return [ form.firm, form.facebook_page, form ] if form
      end

      page = FacebookPage.across_firms.find_by(page_id:)
      return [ page.firm, page, nil ] if page

      Log.info("unknown_page", page_id:)
      nil
    end

    def upsert(firm, page, form)
      existing = FacebookLeadImport.across_firms.find_by(leadgen_id:)
      if existing
        existing.update!(raw_payload: value) if existing.pending? || existing.failed? || existing.processing?
        return [ existing, false ]
      end

      import = FacebookLeadImport.create!(
        firm:,
        facebook_page: page,
        facebook_lead_form: form,
        leadgen_id:,
        status: :pending,
        raw_payload: value
      )
      [ import, true ]
    rescue ActiveRecord::RecordNotUnique
      [ FacebookLeadImport.across_firms.find_by!(leadgen_id:), false ]
    end
  end
end
