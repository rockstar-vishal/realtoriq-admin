# frozen_string_literal: true

module Inbound
  # The note the owner copies into WhatsApp. Built here so the screen and the
  # contract cannot drift.
  class Instructions
    def self.payload(credential, base_url)
      origin = base_url.to_s.sub(%r{/\z}, "")
      {
        token: credential.token,
        portals: Channels::ALL.map { |channel| portal(credential.token, origin, channel) }
      }
    end

    def self.portal(token, origin, channel)
      projects_url = "#{origin}/api/v1/inbound/#{channel}/projects"
      properties_url = "#{origin}/api/v1/inbound/#{channel}/properties"
      {
        channel:,
        label: Channels.label(channel),
        projects_url:,
        properties_url:,
        message: message(token, channel, projects_url, properties_url)
      }
    end

    def self.message(token, channel, projects_url, properties_url)
      project_hint = if Channels.portal?(channel)
        "the code saved on the project, or the P- code, or the exact project name"
      else
        "the P- code, or the exact project name"
      end
      property_hint = if Channels.portal?(channel)
        "the code saved on the property, or the H- code"
      else
        "the H- code"
      end
      codes = if Channels.portal?(channel)
        "Save the portal's listing code on the project or property in RealtorIQ first. The button is called Portal codes.\n"
      else
        ""
      end

      <<~TEXT.strip
        Please send new #{Channels.label(channel)} enquiries to RealtorIQ.

        Project enquiries
        POST #{projects_url}
        Authorization: Bearer #{token}
        Content-Type: application/json

        { "name": "Rahul Sharma", "mobile": "9876543210", "listing": "#{project_hint}" }

        We fill the budget, location and configuration from that project. Do not send sale, rent, budget or location.

        Property enquiries
        POST #{properties_url}
        Authorization: Bearer #{token}
        Content-Type: application/json

        { "name": "Rahul Sharma", "mobile": "9876543210", "listing": "#{property_hint}" }

        Sale or rent, budget and location come from the property. Do not send them.

        #{codes}#{extra(channel)}
      TEXT
    end

    def self.extra(channel)
      return "" if Channels.portal?(channel)

      <<~TEXT.strip
        If you do not have a project, send budget, city, locality and configuration instead of listing. The lead is saved as a sale under construction.

        If you do not have a property, send budget, city, locality, configuration and transaction_type ("sale" or "rent"). Budget is whole rupees, for example 12000000.
      TEXT
    end
    private_class_method :portal, :message, :extra
  end
end
