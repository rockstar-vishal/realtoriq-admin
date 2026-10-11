# frozen_string_literal: true

module Sites
  # The home form. This is a message to the broker, not a lead. A project or
  # property page is the only place an enquiry becomes a lead.
  class ReceiveContact
    NAME_MAX = 80
    MESSAGE_MAX = 500
    Result = Struct.new(:ok?, :error, keyword_init: true)

    def self.call(...)
      new(...).call
    end

    def initialize(firm:, name:, mobile:, message:)
      @firm = firm
      @name = clip(name, NAME_MAX).tr("\r\n", " ").strip
      @mobile = mobile
      @message = clip(message, MESSAGE_MAX).strip
    end

    def call
      return failure("Name is required.") if name.blank?

      phone = indian_mobile(mobile)
      return failure("Enter a 10-digit mobile number.") if phone.nil?
      return failure("Message is required.") if message.blank?

      owner = firm.super_admin
      return failure("Could not send that just now.") if owner.nil? || owner.disabled?

      to = recipient_email(owner)
      return failure("Could not send that just now.") if to.blank?

      ContactNotifyJob.perform_later(firm.id, to, firm.name, name, phone, message)
      Result.new(ok?: true)
    end

    private

    attr_reader :firm, :name, :mobile, :message

    # The firm's verified email is the business inbox. The super admin's own
    # address is the fallback when that channel is not verified yet.
    def recipient_email(owner)
      channel = ContactChannel.unscoped.find_by(
        firm_id: firm.id, kind: "email", verification_state: "verified"
      )
      email = channel&.value.presence || owner.email.presence
      cleaned = email.to_s.delete("\u0000").tr("\r\n", "").strip
      cleaned if cleaned.match?(URI::MailTo::EMAIL_REGEXP)
    end

    def indian_mobile(value)
      phone = Phone.normalise(value)
      phone if phone&.match?(/\A\+91[6-9]\d{9}\z/)
    end

    def clip(value, max)
      value.to_s.delete("\u0000")[0, max]
    end

    def failure(error)
      Result.new(ok?: false, error:)
    end
  end
end
