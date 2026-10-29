# frozen_string_literal: true

module Marketing
  # The firm's verified channels. A creative never prints an unverified number.
  class FirmContacts
    def initialize(firm)
      @firm = firm
    end

    def mobile = e164("mobile")
    def whatsapp = e164("whatsapp")

    def email
      verified("email")&.value.presence
    end

    def phone_e164
      mobile.presence || whatsapp
    end

    def phone_display
      Phone.format_for_display(phone_e164) if phone_e164
    end

    def whatsapp_e164
      whatsapp
    end

    def whatsapp_digits
      whatsapp&.delete_prefix("+")
    end

    def whatsapp_display
      Phone.format_for_display(whatsapp) if whatsapp
    end

    def call_line
      left = display(mobile)
      right = display(whatsapp)
      if left && right
        return "Call / WhatsApp #{left}" if mobile == whatsapp

        "Call #{left} · WhatsApp #{right}"
      elsif left
        "Call #{left}"
      elsif right
        "WhatsApp #{right}"
      end
    end

    def maharashtra?(project)
      project&.city&.state.to_s.casecmp("maharashtra").zero?
    end

    def authority(project)
      maharashtra?(project) ? "MahaRERA" : "RERA"
    end

    def agent_label(project)
      "#{authority(project)} Agent Reg. No."
    end

    def agent_line(project)
      "#{agent_label(project)} #{firm.rera_number}"
    end

    def project_line(numbers)
      listed = Array(numbers).map { |number| number.to_s.strip }.reject(&:blank?).join(", ")
      "Project Reg. No. #{listed}"
    end

    private

    attr_reader :firm

    def e164(kind)
      value = verified(kind)&.value
      return if value.blank?

      Phone.normalise(value)
    end

    def display(value)
      Phone.format_for_display(value) if value.present?
    end

    def verified(kind)
      return if firm.nil?

      channels = firm.contact_channels
      if channels.respond_to?(:verification_verified)
        channels.verification_verified.find_by(kind:)
      else
        Array(channels).find { |row| row.kind.to_s == kind && channel_verified?(row) }
      end
    end

    def channel_verified?(row)
      return row.verified? if row.respond_to?(:verified?)

      row.verification_state.to_s == "verified"
    end
  end
end
