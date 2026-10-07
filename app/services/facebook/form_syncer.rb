# frozen_string_literal: true

module Facebook
  # Pulls a Page's lead forms. A form another firm already owns is left alone.
  class FormSyncer
    Result = Struct.new(:forms_count, :mapped, :available, :errors, keyword_init: true) do
      def success?
        errors.blank?
      end
    end

    def self.sync_page!(page, api: nil)
      new(page, api:).sync!
    end

    def initialize(page, api: nil)
      @page = page
      @api = api
    end

    def sync!
      api = @api || GraphApiClient.new(access_token: @page.page_access_token)
      forms = api.list_lead_forms(@page.page_id)
      catalog = forms.map { |form_data| catalog_entry(form_data) }
      catalog.each { |entry| refresh_owned_form!(entry) }
      @page.update!(form_catalog: catalog, forms_synced_at: Time.current)
      counts = count_listings
      Result.new(forms_count: forms.size, mapped: counts[:mapped], available: counts[:available], errors: [])
    rescue Errors::Base => e
      TokenManager.handle_api_error(@page.facebook_connection, e, page: @page)
      failed_sync
    rescue Koala::Facebook::APIError, Faraday::Error => e
      Log.error("form_sync", page_id: @page.page_id, error_class: e.class.name,
        code: (e.fb_error_code if e.respond_to?(:fb_error_code)))
      failed_sync
    rescue ActiveRecord::Encryption::Errors::Decryption
      Result.new(forms_count: 0, mapped: 0, available: 0, errors: [ "Could not read the Page token" ])
    end

    private

    def catalog_entry(form_data)
      {
        "form_id" => form_data[:form_id].to_s,
        "form_name" => form_data[:form_name].to_s,
        "status" => form_data[:status].to_s,
        "questions" => FieldMapper.normalize_questions(form_data[:questions])
      }
    end

    def refresh_owned_form!(entry)
      form = FacebookLeadForm.across_firms.find_by(form_id: entry["form_id"])
      return if form && form.firm_id != @page.firm_id

      if form.nil?
        form = FacebookLeadForm.new(
          form_id: entry["form_id"],
          facebook_page: @page,
          firm: @page.firm
        )
      end

      form.facebook_page = @page
      form.form_name = entry["form_name"].presence || form.form_name
      form.questions = entry["questions"]
      form.meta_status = entry["status"]
      meta_active = entry["status"].to_s.upcase == "ACTIVE"
      if form.new_record?
        form.active = meta_active
      elsif !meta_active
        form.active = false
      end
      form.save!
    rescue ActiveRecord::RecordInvalid
      Log.error("form_sync_save", form_id: entry["form_id"], error_class: "ActiveRecord::RecordInvalid")
    end

    def failed_sync
      Result.new(forms_count: 0, mapped: 0, available: 0, errors: [ "Could not sync forms" ])
    end

    def count_listings
      counts = { mapped: 0, available: 0 }
      @page.form_listings.each { |listing| counts[listing.state] = counts.fetch(listing.state, 0) + 1 }
      counts
    end
  end
end
