# frozen_string_literal: true

require "cgi"
require "rqrcode"
require "vips"

module Marketing
  # The hash the kit templates already use. Values are raw; Mustache escapes
  # them. whatsapp_text is encoded first so a second escape cannot change it.
  class KitData
    ACCENT = "#1d4ed8"
    FORM_HANDLER = "YOUR-FORM-HANDLER-URL"
    TEMPLATE_ROOT = Rails.root.join("app/views/marketing/kit")

    def initialize(project, firm, dir)
      @project = project
      @firm = firm
      @dir = dir
      @contacts = FirmContacts.new(firm)
      @prepared = Time.current.in_time_zone("Asia/Kolkata").to_date
    end

    def prepared_on_date = @prepared

    def to_h
      authority = Authorities.for(project)
      registrations = registration_rows
      photos = photo_rows
      configurations = configuration_rows
      {
        "accent" => ACCENT,
        "prepared_on" => prepared_on,
        "form_handler_url" => FORM_HANDLER,
        "whatsapp_text" => CGI.escape("Hi, I'm interested in #{project.name}"),
        "suggested_domain" => suggested_domain,
        "inbound_projects_url" => inbound_projects_url,
        "firm" => firm_hash,
        "project" => project_hash(photos, configurations),
        "rera" => authority.merge(
          "registrations" => registrations,
          "numbers_text" => registrations.map { |row| row["number"] }.join(", ")
        )
      }
    end

    def prepared_on
      "#{@prepared.day} #{@prepared.strftime("%b %Y")}"
    end

    def disclaimer(data)
      firm_name = data.dig("firm", "name")
      builder = data.dig("project", "builder")
      website = data.dig("rera", "website").presence || "the RERA website"
      authority = data.dig("rera", "authority")
      numbers = data.dig("rera", "numbers_text")
      "This website is managed by #{firm_name}, a registered real estate agent. " \
        "It is not the official website of #{builder}. Project details, prices, plans and images " \
        "are indicative and based on information shared by the developer; please verify them " \
        "with the developer and on #{website} before booking. #{authority} registration: #{numbers}."
    end

    private

    attr_reader :project, :firm, :dir, :contacts

    def firm_hash
      {
        "name" => firm.name,
        "logo" => write_logo,
        "phone_display" => contacts.phone_display,
        "phone_e164" => contacts.phone_e164,
        "whatsapp_e164" => contacts.whatsapp_e164,
        "whatsapp_digits" => contacts.whatsapp_digits,
        "whatsapp_display" => contacts.whatsapp_display,
        "email" => contacts.email,
        "rera_label" => contacts.agent_label(project),
        "rera_number" => firm.rera_number
      }
    end

    def project_hash(photos, configurations)
      {
        "name" => project.name,
        "builder" => project.builder&.name,
        "locality" => project.locality&.name,
        "city" => project.city&.name,
        "address" => project.address.presence,
        "code" => project.code,
        "configurations_text" => configurations.map { |row| row["name"] }.uniq.join(", ").presence,
        "category_text" => project.categories.map { |code| Typology::LABELS[code] }.compact.join(", ").presence,
        "possession_text" => possession_text,
        "starting_price_text" => starting_price_text,
        "promo_text" => project.promo_live? ? project.promo_text : nil,
        "brochure" => brochure_path,
        "map_url" => map_url,
        "hero_image" => photos.first&.dig("src") && hero_path(photos),
        "photos" => photos,
        "has_photos" => photos.any?,
        "configurations" => configurations,
        "has_configurations" => configurations.any?
      }
    end

    def possession_text
      return "Ready to Move" if Inventory::PossessionMatch.ready?(project)
      return if project.possession_display.blank?

      "Possession #{project.possession_display}"
    end

    def starting_price_text
      amount = project.starting_budget
      return if amount.blank? || amount.to_i <= 0

      "#{Project.compact_rupees(amount)} Onwards"
    end

    def configuration_rows
      project.project_typologies.includes(:typology).map { |row|
        {
          "name" => row.display_name,
          "area_text" => area_text(row),
          "price_text" => row.starting_price.present? ? Project.compact_rupees(row.starting_price) : nil
        }
      }
    end

    def area_text(row)
      quantity = AreaUnits.display_quantity(row.area_value)
      quantity ||= row.starting_carpet_sqft if row.starting_carpet_sqft.to_i.positive?
      return if quantity.blank?

      unit = AreaUnits::LABELS[row.area_unit] || "sq ft"
      "#{quantity} #{unit} #{row.typology&.area_kind}".strip
    end

    def map_url
      return if project.lat.blank? || project.lng.blank? || project.pin_approximate?

      "https://www.google.com/maps?q=#{project.lat},#{project.lng}"
    end

    def suggested_domain
      "#{firm.name.to_s.downcase.gsub(/[^a-z0-9]/, "")}.in"
    end

    def inbound_projects_url
      opts = Rails.application.routes.default_url_options
      host = opts[:host]
      return if host.blank?

      protocol = opts[:protocol].presence || "http"
      base = "#{protocol}://#{host}"
      port = opts[:port]
      base = "#{base}:#{port}" if port.present? && ![ 80, 443 ].include?(port.to_i)
      "#{base}/api/v1/inbound/general/projects"
    end

    def registration_rows
      Registrations.for(project).map { |row|
        qr = write_qr(row["number"], row["maharera_url"])
        { "label" => row["label"], "number" => row["number"], "qr" => qr }
      }
    end

    def write_qr(number, url)
      return if url.blank?

      safe = number.to_s.gsub(/[^A-Za-z0-9]/, "")
      qr = RQRCode::QRCode.new(url)
      File.binwrite(File.join(dir, "assets", "rera-qr-#{safe}.png"), qr.as_png(size: 1024).to_blob)
      File.write(File.join(dir, "assets", "rera-qr-#{safe}.svg"), qr.as_svg)
      "assets/rera-qr-#{safe}.png"
    end

    def photo_rows
      project.photos.attachments.sort_by { |attachment| [ attachment.created_at, attachment.id ] }.filter_map.with_index(1) { |attachment, index|
        name = format("photo-%02d.jpg", index)
        dest = File.join(dir, "assets", name)
        next unless write_photo(attachment, dest)

        { "src" => "assets/#{name}", "alt" => "#{project.name} photo #{index}" }
      }
    end

    def hero_path(photos)
      source = File.join(dir, photos.first["src"])
      dest = File.join(dir, "assets", "hero.jpg")
      FileUtils.cp(source, dest)
      "assets/hero.jpg"
    end

    def write_photo(attachment, dest)
      attachment.blob.open do |file|
        image = Vips::Image.new_from_file(file.path, access: :sequential)
        if image.width > 1600 || image.height > 1600
          image = image.thumbnail_image(1600, height: 1600, size: :down)
        end
        image = image.flatten(background: [ 255, 255, 255 ]) if image.has_alpha?
        image.write_to_file(dest, Q: 82, strip: true)
      end
      true
    rescue Vips::Error
      false
    end

    def write_logo
      return unless firm.logo.attached?

      dest = File.join(dir, "assets", "logo.png")
      firm.logo.blob.open do |file|
        image = Vips::Image.new_from_file(file.path, access: :sequential)
        image.write_to_file(dest)
      end
      "assets/logo.png"
    rescue Vips::Error
      nil
    end

    def brochure_path
      url = project.brochure_source_url.to_s
      if url.present?
        return fetch_brochure(url) if remote_allowed?(url)

        return url
      end
      return unless project.brochure.attached?

      dest = File.join(dir, "assets", "brochure.pdf")
      File.binwrite(dest, project.brochure.download)
      "assets/brochure.pdf"
    end

    def remote_allowed?(url)
      uri = URI.parse(url)
      uri.is_a?(URI::HTTPS) && Realtoriq::RemoteFile.allowed_host?(uri)
    rescue URI::InvalidURIError
      false
    end

    def fetch_brochure(url)
      io = Realtoriq::RemoteFile.fetch(url, content_types: Realtoriq::RemoteFile::BROCHURE_TYPES)
      dest = File.join(dir, "assets", "brochure.pdf")
      File.binwrite(dest, io.is_a?(String) ? io : io.read)
      "assets/brochure.pdf"
    rescue Realtoriq::RemoteFile::Error
      url
    ensure
      io.close! if defined?(io) && io.is_a?(Tempfile)
    end
  end
end
