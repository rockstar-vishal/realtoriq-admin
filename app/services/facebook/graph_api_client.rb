# frozen_string_literal: true

require "koala"

module Facebook
  # Graph calls for Lead Ads. Raises typed errors. Never logs the token.
  class GraphApiClient
    MAX_PAGES = 50
    LEAD_FIELDS = "field_data,form_id,ad_id,ad_name,created_time,is_organic"

    def initialize(access_token:)
      @api = Koala::Facebook::API.new(access_token)
    end

    def fetch_lead(leadgen_id)
      Log.info("fetch_lead", leadgen_id:)
      @api.get_object(leadgen_id, fields: LEAD_FIELDS)
    rescue Koala::Facebook::ClientError => e
      typed = Errors.from_koala(e)
      raise typed if typed.is_a?(Errors::TokenInvalidError) || typed.is_a?(Errors::RateLimitError)

      raise Errors::LeadFetchError.new(
        "Failed to fetch lead",
        fb_error_code: e.fb_error_code,
        fb_error_subcode: e.fb_error_subcode,
        fb_error_type: e.fb_error_type
      )
    end

    # /me/accounts plus Business portfolio pages, with tokens filled in.
    def list_pages
      Log.info("list_pages")
      by_id = {}
      collect_me_accounts.each { |page| merge_page!(by_id, page) }
      collect_business_portfolio_pages.each { |page| merge_page!(by_id, page) }
      resolve_missing_page_tokens!(by_id)
      by_id.values.select { |page| page[:page_access_token].present? }
    rescue Koala::Facebook::ClientError => e
      raise Errors.from_koala(e)
    end

    def list_lead_forms(page_id)
      Log.info("list_lead_forms", page_id:)
      forms = paginate_connection(page_id, "leadgen_forms", fields: "id,name,status,questions")
      forms.map do |form|
        {
          form_id: form["id"],
          form_name: form["name"],
          status: form["status"],
          questions: form["questions"] || []
        }
      end
    rescue Koala::Facebook::ClientError => e
      raise Errors.from_koala(e)
    end

    # Subscribe the Page to the leadgen field. Must be a page token.
    def subscribed_apps(page_id)
      Log.info("subscribed_apps", page_id:)
      result = @api.put_connections(page_id, "subscribed_apps", { subscribed_fields: "leadgen" })
      result["success"] == true
    rescue Koala::Facebook::ClientError => e
      typed = Errors.from_koala(e)
      raise typed if typed.is_a?(Errors::TokenInvalidError)

      raise Errors::WebhookSubscriptionError.new(
        "Failed to subscribe page",
        fb_error_code: e.fb_error_code
      )
    end

    def unsubscribe_page(page_id)
      Log.info("unsubscribe_page", page_id:)
      result = @api.delete_connections(page_id, "subscribed_apps")
      result["success"] == true
    rescue Koala::Facebook::ClientError => e
      raise Errors.from_koala(e)
    end

    def debug_token(input_token:)
      Log.info("debug_token")
      result = @api.get_object("debug_token", input_token:)
      return result["data"] if result.is_a?(Hash) && result["data"].is_a?(Hash)

      result
    rescue Koala::Facebook::ClientError => e
      raise Errors.from_koala(e)
    end

    def verify_token(fields: "id,name")
      Log.info("verify_token")
      @api.get_object("me", fields:)
    rescue Koala::Facebook::ClientError => e
      raise Errors.from_koala(e)
    end

    def business_name(business_id)
      return if business_id.blank?

      Log.info("business_name", business_id:)
      @api.get_object(business_id.to_s, fields: "id,name")["name"].presence
    rescue Koala::Facebook::ClientError
      nil
    end

    private

    def collect_me_accounts
      paginate_connection("me", "accounts", fields: "id,name,access_token,tasks").map { |account| page_hash(account) }
    end

    def collect_business_portfolio_pages
      pages = []
      businesses = paginate_connection("me", "businesses", fields: "id,name")
      businesses.each do |business|
        business_id = business["id"]
        next if business_id.blank?

        %w[owned_pages client_pages].each do |edge|
          paginate_connection(business_id, edge, fields: "id,name").each do |page|
            pages << page_hash(page)
          end
        rescue Koala::Facebook::ClientError => e
          Log.warn("list_pages_business_edge", business_id:, edge:, code: e.fb_error_code)
        end
      end
      pages
    rescue Koala::Facebook::ClientError => e
      Log.warn("list_pages_businesses", code: e.fb_error_code)
      []
    end

    def resolve_missing_page_tokens!(by_id)
      by_id.each_value do |page|
        next if page[:page_access_token].present? || page[:page_id].blank?

        details = @api.get_object(page[:page_id], fields: "id,name,access_token,tasks")
        page[:page_name] = details["name"].presence || page[:page_name]
        page[:page_access_token] = details["access_token"] if details["access_token"].present?
        page[:tasks] = details["tasks"] || page[:tasks]
      rescue Koala::Facebook::ClientError => e
        Log.warn("list_pages_token_resolve", page_id: page[:page_id], code: e.fb_error_code)
      end
    end

    def merge_page!(by_id, page)
      id = page[:page_id].to_s
      return if id.blank?

      existing = by_id[id]
      if existing.nil?
        by_id[id] = page
      elsif page[:page_access_token].present? && existing[:page_access_token].blank?
        by_id[id] = page
      elsif page[:page_access_token].present?
        existing[:page_name] = page[:page_name] if page[:page_name].present?
        existing[:tasks] = page[:tasks] if page[:tasks].present?
      end
    end

    def page_hash(raw)
      {
        page_id: raw["id"].to_s,
        page_name: raw["name"],
        page_access_token: raw["access_token"],
        tasks: raw["tasks"] || []
      }
    end

    def paginate_connection(object_id, connection, fields:)
      results = []
      collection = @api.get_connections(object_id, connection, fields:, limit: 100)
      pages_fetched = 0
      while collection
        results.concat(collection.to_a)
        pages_fetched += 1
        break if pages_fetched >= MAX_PAGES

        collection = collection.next_page
        break if collection.nil? || collection.empty?
      end
      results
    end
  end
end
