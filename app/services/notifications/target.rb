# frozen_string_literal: true

module Notifications
  # Turns inbox data into an in-app path. Nil means the row is not clickable.
  #
  # page opens that screen. item opens its show page and ignores params.
  # params is a flat filter for the list, never part of the path, so a row
  # cannot send the browser to another site.
  class Target
    PAGES = %w[home leads projects properties bookings settings team reports subscription].freeze
    ITEM = /\A[A-Za-z0-9_-]+\z/
    PARAM_KEY = /\A[A-Za-z0-9_]+\z/

    def self.url(data)
      new(data).url
    end

    def initialize(data)
      @data = data.is_a?(Hash) ? data.stringify_keys : {}
    end

    def url
      page = data["page"].to_s
      return nil unless PAGES.include?(page)
      return "/" if page == "home"

      item = data["item"].presence
      if item
        item = item.to_s
        return nil unless item.match?(ITEM)

        return "/#{page}/#{item}"
      end

      query = query_string
      return nil if query.nil?

      query.empty? ? "/#{page}" : "/#{page}?#{query}"
    end

    private

    attr_reader :data

    # nil means the params are not a flat map of strings, so the row must not
    # be clickable. An empty string means there is no query.
    def query_string
      raw = data["params"]
      return "" if raw.blank?
      return nil unless raw.is_a?(Hash)

      pairs = raw.map do |key, value|
        return nil unless key.to_s.match?(PARAM_KEY)
        return nil unless value.is_a?(String) || value.is_a?(Numeric)

        [ key.to_s, value.to_s ]
      end
      URI.encode_www_form(pairs)
    end
  end
end
