# frozen_string_literal: true

module Sites
  # Safe fields for one firm's public pages. Brokerage, portal codes, RM
  # fields and confidential notes are never copied onto these hashes.
  class Catalog
    RASTER = %w[image/png image/jpeg image/webp].freeze

    def initialize(firm)
      @firm = firm
    end

    def projects
      rows = Project.unscoped
        .where(firm_id: firm.id, source: "own", status: "active", on_website: true)
        .includes(:builder, :city, :locality, project_typologies: :typology)
        .order(:name, :id)
      covers = covers_for("Project", rows.map(&:id))
      rows.map { |project| project_card(project, covers[project.id]) }
    end

    def properties
      rows = Property.unscoped
        .where(firm_id: firm.id, status: "available", on_website: true)
        .includes(:typology, :city, :locality)
        .order(:created_at, :id)
      covers = covers_for("Property", rows.map(&:id))
      rows.map { |property| property_card(property, covers[property.id]) }
    end

    def project_by_code(code)
      show_project(visible_project(code: code.to_s.upcase))
    end

    def project(slug)
      show_project(visible_project(slug:))
    end

    def property_by_code(code)
      show_property(visible_property(code: code.to_s.upcase))
    end

    def property(slug)
      show_property(visible_property(slug:))
    end

    def show_project(record)
      return nil if record.nil?

      project_card(record, nil).merge(
        photos: photo_urls(record),
        address: record.address,
        rera_number: record.rera_number,
        promo_text: record.promo_live? ? record.promo_text : nil,
        brochure_url: brochure_url(record),
        lat: coordinate(record.lat),
        lng: coordinate(record.lng),
        configurations: record.project_typologies.map { |row| configuration(row) }
      )
    end

    def show_property(record)
      return nil if record.nil?

      property_card(record, nil).merge(
        photos: photo_urls(record),
        description: record.description,
        floor_band: record.floor_band,
        carpet_area_sqft: record.carpet_area_sqft,
        category_label: Typology.label_for(record.typology&.category),
        area_label: area_label(record),
        area_text: area_text(record.area_value, record.area_unit, record.carpet_area_sqft),
        details: public_details(record),
        lease: public_lease(record),
        has_pool: record.has_pool,
        has_gym: record.has_gym
      )
    end

    private

    attr_reader :firm

    def visible_project(conditions)
      return nil unless Host.code?(conditions[:code].to_s) || conditions[:slug].present?

      Project.unscoped.includes(:builder, :city, :locality, project_typologies: :typology)
        .find_by({ firm_id: firm.id, source: "own", status: "active", on_website: true }.merge(conditions))
    end

    def visible_property(conditions)
      return nil unless Host.code?(conditions[:code].to_s) || conditions[:slug].present?

      Property.unscoped.includes(:typology, :city, :locality)
        .find_by({ firm_id: firm.id, status: "available", on_website: true }.merge(conditions))
    end

    def project_card(project, cover)
      {
        slug: project.slug,
        code: project.code.to_s.downcase,
        path: Host.listing_path("projects", project.code, project.name),
        name: project.name,
        builder_name: project.builder&.name,
        city: project.city&.name,
        locality: project.locality&.name,
        starting_budget: project.starting_budget,
        categories: project.categories,
        price_summary: project.price_summary,
        possession_display: project.possession_display,
        configuration_names: project.project_typologies.filter_map { |row| row.display_name }.uniq,
        cover_url: cover && Api::V1::BlobUrl.call(cover)
      }
    end

    def property_card(property, cover)
      {
        slug: property.slug,
        code: property.code.to_s.downcase,
        path: Host.listing_path("properties", property.code, property.title),
        title: property.title,
        listing_for: property.listing_for,
        price: property.price,
        building_name: property.building_name,
        locality: property.locality&.name,
        city: property.city&.name,
        category: property.typology&.category,
        cover_url: cover && Api::V1::BlobUrl.call(cover)
      }
    end

    def configuration(row)
      {
        name: row.display_name,
        category: row.typology&.category,
        starting_price: row.starting_price,
        starting_carpet_sqft: row.starting_carpet_sqft,
        area_text: area_text(row.area_value, row.area_unit, row.starting_carpet_sqft)
      }
    end

    def area_label(property)
      property.typology&.land? ? "Plot area" : "Carpet"
    end

    def area_text(value, unit, sqft)
      unit = unit.presence || "sqft"
      quantity = AreaUnits.display_quantity(value)
      label = AreaUnits::LABELS.fetch(unit, unit)
      sqft_text = sqft.present? ? "#{grouped_number(sqft)} sq ft" : nil
      if unit == "sqft" || quantity.blank?
        return sqft_text if sqft_text
        return "#{quantity} #{label}" if quantity.present?

        return nil
      end

      own = "#{quantity} #{label}"
      sqft_text && sqft_text != "#{quantity} sq ft" ? "#{own} (#{sqft_text})" : own
    end

    def grouped_number(number)
      digits = number.to_i.abs.to_s
      return digits if digits.length <= 3

      head = digits[0...-3].reverse.gsub(/(\d{2})(?=\d)/, '\\1,').reverse
      "#{head},#{digits[-3..]}"
    end

    def public_details(property)
      specs = Inventory::DetailSpecs.fields_for(property.typology&.code, pre_leased: false)
      values = property.details.to_h
      specs.filter_map { |spec|
        raw = values[spec.key]
        next if raw.nil? || raw == ""

        { label: spec.label, value: detail_value(spec, raw) }
      }
    end

    def detail_value(spec, raw)
      case spec.type
      when :boolean
        ActiveModel::Type::Boolean.new.cast(raw) ? "Yes" : "No"
      when :select
        Inventory::DetailSpecs.option_label(raw.to_s)
      else
        text = raw.is_a?(Numeric) ? AreaUnits.display_quantity(raw) : raw.to_s
        spec.unit.present? ? "#{text} #{spec.unit}" : text
      end
    end

    def public_lease(property)
      payload = property.lease_payload
      return nil if payload.nil?

      tenant = payload[:tenant_type].presence
      {
        monthly_rent: payload[:monthly_rent],
        lock_in_until: payload[:lock_in_until],
        tenant: tenant && Inventory::DetailSpecs.option_label(tenant),
        yield_percent: payload[:yield_percent]
      }
    end

    def covers_for(record_type, ids)
      return {} if ids.empty?

      # The first photo only. Loading every attachment for the firm pulls the
      # whole gallery into this request.
      attachments = ActiveStorage::Attachment
        .where(record_type:, record_id: ids, name: "photos")
        .select("DISTINCT ON (active_storage_attachments.record_id) active_storage_attachments.*")
        .order("active_storage_attachments.record_id, active_storage_attachments.created_at, active_storage_attachments.id")
        .to_a
      ActiveRecord::Associations::Preloader.new(records: attachments, associations: :blob).call
      attachments.index_by(&:record_id)
    end

    def photo_urls(record)
      record.photos.attachments.sort_by { |attachment| [ attachment.created_at, attachment.id ] }
        .filter_map { |attachment| Api::V1::BlobUrl.call(attachment) }
    end

    def brochure_url(project)
      Realtoriq::BrochureUrl.for(project)
    end

    def coordinate(value)
      value&.to_d&.to_s("F")
    end
  end
end
