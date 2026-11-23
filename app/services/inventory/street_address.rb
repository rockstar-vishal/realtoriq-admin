# frozen_string_literal: true

module Inventory
  # A street address is shown under the map. A link pasted into that field is
  # not an address: the pin and "Open in Google Maps" already cover a maps
  # link, and the raw URL is one long token that blows the page out sideways.
  module StreetAddress
    MAPS_HOST = Regexp.union(
      %r{\A(?:https?://)?(?:www\.)?maps\.app\.goo\.gl/\S+\z}i,
      %r{\A(?:https?://)?(?:www\.)?goo\.gl/maps(?:/\S*)?\z}i,
      %r{\A(?:https?://)?(?:www\.)?maps\.google\.[a-z.]+/\S*\z}i,
      %r{\A(?:https?://)?(?:www\.)?google\.[a-z.]+/maps\S*\z}i
    )
    WEB_URL = %r{\Ahttps?://\S+\z}i
    BARE_URL = %r{\A(?:www\.)?[a-z0-9.-]+\.[a-z]{2,}/\S+\z}i

    module_function

    def street_address(value)
      text = value.to_s.strip
      return if text.empty? || location_link?(text)

      text
    end

    # The stored value, when it is itself a Google Maps link. Nil for a street
    # address and for any other URL.
    def maps_link(value)
      text = value.to_s.strip
      return unless text.match?(MAPS_HOST)

      text.match?(%r{\Ahttps?://}i) ? text : "https://#{text}"
    end

    def location_link?(text)
      text.match?(MAPS_HOST) || text.match?(WEB_URL) || text.match?(BARE_URL)
    end
  end
end
