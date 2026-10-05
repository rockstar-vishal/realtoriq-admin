# frozen_string_literal: true

module Inbound
  # In-app only. A failure still reaches the owner when notifications are
  # off, because the buyer would otherwise disappear. The key is never included.
  #
  # Distinct rejections are capped per firm per day. A portal that varies the
  # mobile on every call must not be able to fill the inbox or buzz the phone.
  class Notify
    def self.failure(user:, channel:, mobile:, listing:, message:)
      return if user.nil?
      return unless Throttle.failure_notices_left?(user.firm_id)

      day = Time.find_zone(Lead::NCD_ZONE).today.iso8601
      fingerprint = Digest::SHA256.hexdigest([ channel, mobile.to_s, listing.to_s, message.to_s ].join("\u0001"))
      result = Notifications::Record.call(
        user:,
        kind: "inbound_enquiry",
        title: "Website enquiry was not saved",
        body: [ Channels.label(channel), clip(mobile.presence || "No mobile", 32), clip(listing, 80).presence,
          clip(message, 160) ].compact.join(" · "),
        dedupe_key: "inbound_reject:#{fingerprint}:#{day}",
        force: true,
        data: {}
      )
      Throttle.record_failure_notice(user.firm_id) if result.created
    end

    def self.success(user:, channel:, lead:, enquiry_id:, listing_name:, created:)
      return if user.nil? || lead.nil?

      label = Channels.label(channel)
      title = created ? "New #{label} enquiry" : "#{label} enquiry on #{lead.code}"
      dedupe_key = if enquiry_id.present?
        "inbound:#{channel}:#{Digest::SHA256.hexdigest(enquiry_id)}"
      else
        "inbound:#{lead.id}:#{SecureRandom.uuid}"
      end
      Notifications::Record.call(
        user:,
        kind: "inbound_enquiry",
        title:,
        body: clip(listing_name.presence || "A client", 160),
        dedupe_key:,
        data: { "page" => "leads", "item" => lead.id }
      )
    end

    def self.clip(value, max)
      value.to_s.delete("\u0000")[0, max]
    end
    private_class_method :clip
  end
end
