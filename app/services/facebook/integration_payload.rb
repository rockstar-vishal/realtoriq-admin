# frozen_string_literal: true

module Facebook
  # The Connect Facebook screen. Tokens never leave the server.
  class IntegrationPayload
    def self.call(firm:)
      new(firm:).call
    end

    def initialize(firm:)
      @firm = firm
    end

    def call
      {
        configured: Credentials.configured?,
        system_user_login: Credentials.system_user_login?,
        connection: connection_json,
        pages: pages_json,
        import_counts: import_counts
      }
    end

    private

    attr_reader :firm

    def connection_json
      row = FacebookConnection.current_for(firm)
      return if row.nil?

      {
        "id" => row.id,
        "status" => row.status,
        "fb_user_id" => row.fb_user_id,
        "fb_user_name" => row.fb_user_name,
        "token_kind" => row.token_kind,
        "token_expires_at" => row.token_expires_at&.iso8601,
        "token_obtained_at" => row.token_obtained_at&.iso8601,
        "last_health_check_at" => row.last_health_check_at&.iso8601,
        "connected_at" => row.created_at&.iso8601,
        "error_code" => row.error_code
      }
    end

    def pages_json
      connection = FacebookConnection.current_for(firm)
      return [] if connection.nil?

      connection.facebook_pages.order(:page_name).map { |page| page_json(page) }
    end

    def page_json(page)
      {
        "id" => page.id,
        "page_id" => page.page_id,
        "page_name" => page.page_name,
        "status" => page.status,
        "subscribed" => page.subscribed?,
        "status_message" => page.status_message,
        "form_listings" => page.form_listings.map { |listing| listing_json(listing) }
      }
    end

    def listing_json(listing)
      form = listing.record
      {
        "form_id" => listing.form_id,
        "form_name" => listing.form_name,
        "state" => listing.state.to_s,
        "meta_status" => listing.meta_status,
        "record_id" => form&.id,
        "mapping_summary" => form&.mapping_summary,
        "listing_name" => form&.listing_name,
        "assignee_name" => form&.assigned_user&.name,
        "active" => form&.active,
        "ready_for_import_error" => form&.ready_for_import_error
      }
    end

    def import_counts
      grouped = firm.facebook_lead_imports.group(:status).count
      {
        "total" => grouped.values.sum,
        "created" => grouped["created"].to_i,
        "pending" => grouped["pending"].to_i + grouped["processing"].to_i,
        "failed" => grouped["failed"].to_i,
        "dead" => grouped["dead"].to_i,
        "duplicate" => grouped["duplicate"].to_i
      }
    end
  end
end
