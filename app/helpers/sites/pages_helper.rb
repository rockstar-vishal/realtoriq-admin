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
  end
end
