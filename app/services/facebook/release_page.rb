# frozen_string_literal: true

module Facebook
  # Drops a firm's hold on a Page. Forms and the import log for that Page go
  # with the row. Leads stay. Meta is told only when the row still has a token,
  # and that call stays outside the delete.
  class ReleasePage
    def self.call(page:, actor:)
      unsubscribe_at_meta(page)
      delete_row!(page, actor:)
    end

    def self.delete_row!(page, actor:)
      firm = page.firm
      meta_id = page.page_id
      name = page.page_name
      ActiveRecord::Base.transaction(requires_new: true) do
        AuditEvent.record!(
          subject: page,
          action: "facebook.page_released",
          actor:,
          firm:,
          metadata: { "page_id" => meta_id, "page_name" => name }
        )
        # One DELETE. Forms and imports go with the row through on_delete: :cascade.
        # across_firms: connect runs as the new firm, so the default scope would miss this row.
        FacebookPage.across_firms.where(id: page.id).delete_all
      end
      true
    end

    def self.unsubscribe_at_meta(page)
      return if page.page_access_token.blank?

      GraphApiClient.new(access_token: page.page_access_token).unsubscribe_page(page.page_id)
    rescue StandardError => e
      Log.error("release_unsubscribe", page_id: page.page_id, error_class: e.class.name,
        code: (e.fb_error_code if e.respond_to?(:fb_error_code)))
    end
    private_class_method :unsubscribe_at_meta
  end
end
