# frozen_string_literal: true

module Sites
  module PagesHelper
    def site_initials(firm)
      parts = firm.name.to_s.split(/\s+/)
      letters = if parts.length >= 2
        "#{parts[0][0]}#{parts[1][0]}"
      else
        firm.name.to_s.gsub(/[^A-Za-z0-9]/, "")[0, 2]
      end
      letters.to_s.upcase.presence || "CP"
    end

    def site_logo_url(firm)
      return nil unless firm.public_logo?

      Api::V1::BlobUrl.call(firm.logo)
    end

    def site_rera(firm)
      firm.rera_number.to_s.strip.presence || "Not Available"
    end

    def site_phone(firm)
      phone = firm.website_phone.to_s
      phone if phone.match?(/\A\+91[6-9]\d{9}\z/)
    end

    def tel_href(phone)
      "tel:#{phone}"
    end

    def whatsapp_href(phone)
      "https://wa.me/#{phone.delete('+')}"
    end

    def maps_href(lat, lng)
      return nil if lat.blank? || lng.blank?

      latitude = BigDecimal(lat.to_s)
      longitude = BigDecimal(lng.to_s)
      return nil unless latitude.between?(-90, 90) && longitude.between?(-180, 180)

      format("https://www.google.com/maps/search/?api=1&query=%.7f,%.7f", latitude, longitude)
    end

    def inr(amount)
      return if amount.nil?

      number = amount.to_i
      digits = number.abs.to_s
      formatted = if digits.length <= 3
        digits
      else
        head = digits[0...-3].reverse.gsub(/(\d{2})(?=\d)/, '\\1,').reverse
        "#{head},#{digits[-3..]}"
      end
      "₹#{number.negative? ? '-' : ''}#{formatted}"
    end

    def site_address_lines(firm)
      [ firm.address_line1, firm.address_line2, firm.locality&.name, firm.city&.name, firm.pincode ].compact_blank
    end

    ABOUT_BULLET = /\A\s*(?:[-*]\s+|[•·▪◦►▸➤✓✔☑✅]\uFE0F?\s*|\d{1,2}[.)]\s+)/
    ABOUT_STOP = /(?:[.!?](?=\s+["“‘(]?[[:upper:][:digit:]])|।(?=\s))/
    ABOUT_ABBREVIATIONS = %w[pvt ltd co no nos dr mr mrs ms st rd opp approx etc sq ft vs].freeze
    ABOUT_LEAD_MAX = 160
    ABOUT_HEADING = /\A\s*about(?:\s+us)?\s*[:\-–]?\s*\z/i

    # The firm's About text, shaped for the home page. A short first line or
    # first sentence leads. The rest keeps the firm's own paragraphs, and lines
    # that start with a bullet become a list. The template does the escaping.
    # fold: :phone folds it on a phone only, :all on every screen.
    def about_parts(text)
      text = text.to_s.gsub(/\r\n?/, "\n").strip
      # The page already says "About us"; a first line that only repeats it goes.
      first, rest = text.split("\n", 2)
      text = rest.to_s.strip if first.to_s.match?(ABOUT_HEADING)
      return nil if text.empty?

      lead, rest = about_lead(text)
      blocks = rest.split(/\n[ \t]*\n+/).flat_map { |chunk| about_blocks(chunk) }
      { lead:, blocks:, fold: about_fold(blocks) }
    end

    # Localities across the listings on show, the most listed first.
    def site_areas(*groups)
      names = groups.flatten.filter_map { |listing| listing[:locality].presence }
      names.tally.each_with_index.sort_by { |(_, count), index| [ -count, index ] }.map { |(name, _), _| name }
    end

    private

    def about_lead(text)
      first, rest = text.split("\n", 2)
      first = first.strip
      return [ nil, text ] if first.match?(ABOUT_BULLET) || first.end_with?(":")
      return [ first, rest.to_s.strip ] if first.length.between?(6, ABOUT_LEAD_MAX)

      sentence = about_first_sentence(first)
      return [ nil, text ] if sentence.nil?

      [ sentence, [ first.delete_prefix(sentence).strip, rest.to_s ].join("\n").strip ]
    end

    def about_first_sentence(line)
      offset = 0
      while (match = line.match(ABOUT_STOP, offset))
        stop = match.end(0)
        return nil if stop > ABOUT_LEAD_MAX

        word = line[0...match.begin(0)][/[[:alpha:]]+\z/].to_s.downcase
        return line[0...stop] if stop >= 30 && word.length > 1 && !ABOUT_ABBREVIATIONS.include?(word)

        offset = stop
      end
      nil
    end

    def about_blocks(chunk)
      lines = chunk.lines(chomp: true).map(&:strip).reject(&:empty?)
      lines.chunk_while { |a, b| a.match?(ABOUT_BULLET) == b.match?(ABOUT_BULLET) }.filter_map do |group|
        if group.first.match?(ABOUT_BULLET)
          items = group.map { |line| line.sub(ABOUT_BULLET, "").strip }.reject(&:empty?)
          [ :list, items ] if items.any?
        else
          [ :text, group.join("\n") ]
        end
      end
    end

    # A rough count of phone lines; about 43 characters fit on one.
    def about_fold(blocks)
      size = blocks.sum do |kind, value|
        kind == :list ? value.sum { |item| item.length + 40 } : value.length + (value.count("\n") * 40) + 60
      end
      if size > 1_100
        :all
      elsif size > 440
        :phone
      end
    end
  end
end
