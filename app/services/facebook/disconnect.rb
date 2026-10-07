# frozen_string_literal: true

module Facebook
  # Stops lead delivery for this firm. Pages, forms and imports stay.
  class Disconnect
    def self.call(connection:, actor:)
      new(connection:, actor:).call
    end

    def initialize(connection:, actor:)
      @connection = connection
      @actor = actor
    end

    def call
      connection.facebook_pages.where(subscribed: true).find_each do |page|
        unsubscribe_at_meta(page)
      end

      ActiveRecord::Base.transaction do
        connection.facebook_pages.find_each do |page|
          page.update!(subscribed: false, status: "unsubscribed", status_message: nil, page_access_token: nil)
        end
        connection.update!(access_token: nil, status: "disconnected")
        AuditEvent.record!(subject: connection, action: "facebook.disconnect", actor:, firm: connection.firm)
      end
      true
    end

    private

    attr_reader :connection, :actor

    def unsubscribe_at_meta(page)
      return if page.page_access_token.blank?

      GraphApiClient.new(access_token: page.page_access_token).unsubscribe_page(page.page_id)
    rescue StandardError => e
      Log.error("unsubscribe", page_id: page.page_id, error_class: e.class.name,
        code: (e.fb_error_code if e.respond_to?(:fb_error_code)))
    end
  end
end
