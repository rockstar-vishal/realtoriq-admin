# frozen_string_literal: true

module Realtoriq
  # LaunchIQ sends one row per registration. A URL is kept only when it is a
  # MahaRERA project page, and it is stored without the /public prefix or query.
  module ReraRegistrations
    PATTERN = %r{\Ahttps://maharerait\.maharashtra\.gov\.in/(?:public/)?project/view/(\d+)(?:\?[^#]*)?\z}i
    CANONICAL = "https://maharerait.maharashtra.gov.in/project/view/%s"
    LABEL_MAX = 40

    def self.normalise(rows, project_code:)
      list = rows.is_a?(Array) ? rows : []
      list.filter_map { |row| entry(row, project_code) }
    end

    def self.entry(row, project_code)
      data = row.respond_to?(:to_h) ? row.to_h.stringify_keys : {}
      number = data["number"].to_s.strip.upcase
      return if number.blank?

      label = data["label"].to_s.strip
      {
        "number" => number,
        "label" => label.blank? ? nil : label[0, LABEL_MAX],
        "maharera_url" => url_for(data["maharera_url"], project_code)
      }
    end

    def self.url_for(raw, project_code)
      text = raw.to_s.strip
      return if text.blank?

      match = text.match(PATTERN)
      return format(CANONICAL, match[1]) if match

      Rails.logger.info("rera registration url rejected for #{project_code}")
      nil
    end
  end
end
