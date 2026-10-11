# frozen_string_literal: true

module Sites
  class ContactNotifyJob < TenantJob
    # The arguments include the visitor's name and mobile.
    self.log_arguments = false

    def perform(_firm_id, to, firm_name, sender_name, sender_mobile, body)
      return if to.blank?

      WebsiteContactMailer.message_received(
        to:, firm_name:, sender_name:, sender_mobile:, body:
      ).deliver_now
    end
  end
end
