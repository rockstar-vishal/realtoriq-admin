# frozen_string_literal: true

module Inbound
  # The path picks the lead source. A 99acres key posted to the Housing URL
  # is still this firm's key, but the lead is filed as Housing only when the
  # path says so — the body cannot relabel it.
  module Channels
    ALL = %w[99acres magicbricks housing general].freeze
    PORTALS = %w[99acres magicbricks housing].freeze
    KINDS = %w[projects properties].freeze

    SOURCES = {
      "99acres" => "Portal — 99acres",
      "magicbricks" => "Portal — Magicbricks",
      "housing" => "Portal — Housing",
      "general" => "Website"
    }.freeze

    LABELS = {
      "99acres" => "99acres",
      "magicbricks" => "Magicbricks",
      "housing" => "Housing",
      "general" => "Website"
    }.freeze

    module_function

    def known?(channel) = ALL.include?(channel)

    def kind?(kind) = KINDS.include?(kind)

    def portal?(channel) = PORTALS.include?(channel)

    def column(channel) = PortalListingCodes::COLUMNS[channel]

    def source_name(channel) = SOURCES[channel]

    def label(channel) = LABELS[channel]
  end
end
