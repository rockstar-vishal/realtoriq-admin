# frozen_string_literal: true

module Realtoriq
  # Upsert, hide, or withdraw one marketplace project. Identity is the turbo
  # project code, stored as external_ref. An older pushed_at is ignored.
  # Files are copied after the listing is saved.
  class IngestProject
    Result = Struct.new(:ok?, :status, :error, :project, keyword_init: true)

    CODE_BUILDER = /\ACL[0-9A-F]+\z/i

    def self.call(payload)
      new(payload).call
    end

    def initialize(payload)
      @payload = payload.to_h.deep_stringify_keys
    end

    def call
      return failure("pushed_at is required") if pushed_at.nil?

      case payload["event"]
      when "hide" then hide
      when "withdraw" then withdraw
      when "upsert" then upsert
      else failure("unsupported event")
      end
    end

    private

    attr_reader :payload

    def upsert
      code = payload["project_code"].to_s.strip
      return failure("project_code is required") if code.blank?
      return failure("developer_name is required") if payload["developer_name"].blank?
      return failure("rera_number is required") if payload["rera_number"].blank?
      return failure("possession_on is required") if payload["possession_on"].blank?
      return failure("possession_on is invalid") if possession_on.nil?
      return failure("RM name is required") if payload["rm_name"].blank?
      return failure("RM contact is required") if payload["rm_contact"].blank?

      city = resolve_city
      return city if city.is_a?(Result)
      return failure("locality is required") if payload["locality"].to_s.strip.blank?

      builder = resolve_builder
      return builder if builder.is_a?(Result)

      prices = unit_rows
      return prices if prices.is_a?(Result)

      budget = prices.filter_map { |row| row[:starting_price] }.min
      return failure("a configuration price is required") if budget.nil?

      brokerage = starting_brokerage
      return brokerage if brokerage.is_a?(Result)

      saved = false
      project = nil
      Current.set(firm_scope_bypassed: true) do
        Project.transaction do
          project = lock_catalog(code)
          next if stale?(project)

          previous_builder_id = project&.builder_id
          was_archived = project&.archived? || false
          project ||= Project.new(source: "catalog", firm_id: nil, external_ref: code)
          project.assign_attributes(attributes(city, builder, budget, brokerage))
          project.save!
          # A marketplace brochure is the LaunchIQ link, not a copied file.
          # An illegal URL is :omit and must not wipe a link that is already stored.
          if remote_brochure_url != :omit && project.brochure.attached?
            project.brochure.purge_later
          end
          replace_typologies(project, prices)
          repoint_copies(project, previous_builder_id)
          restore_after_archive(project, was_archived)
          saved = true
        end
      end

      if saved
        # Brochure is not copied. nil tells the job to leave any local file alone.
        SyncProjectAssetsJob.perform_later(
          project.id, image_rows, nil, pushed_at.iso8601, brokerage_ladder_row
        )
        Result.new(ok?: true, status: :accepted, project:)
      else
        ignored(project)
      end
    rescue ActiveRecord::RecordNotUnique
      raise if @retried

      @retried = true
      retry
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence)
    end

    def hide
      code = payload["project_code"].to_s.strip
      return failure("project_code is required") if code.blank?

      project = nil
      Current.set(firm_scope_bypassed: true) do
        Project.transaction do
          project = lock_catalog(code)
          next if project.nil? || stale?(project)

          project.update!(status: "archived", turbo_pushed_at: pushed_at)
        end
      end
      Result.new(ok?: true, status: :ok, project:)
    end

    def withdraw
      code = payload["project_code"].to_s.strip
      return failure("project_code is required") if code.blank?

      project = nil
      Current.set(firm_scope_bypassed: true) do
        Project.transaction do
          project = lock_catalog(code)
          next if project.nil? || stale?(project)

          now = Time.current
          Project.unscoped.where(external_ref: code).update_all(
            status: "archived", turbo_pushed_at: pushed_at, updated_at: now
          )
          ids = Project.unscoped.where(external_ref: code).pluck(:id)
          LeadProject.across_firms.where(project_id: ids, withdrawn_at: nil).update_all(
            withdrawn_at: now, updated_at: now
          )
        end
      end
      Result.new(ok?: true, status: :ok, project:)
    end

    def lock_catalog(code)
      Project.unscoped.lock.find_by(source: "catalog", firm_id: nil, external_ref: code)
    end

    def stale?(project)
      return false if project.nil? || project.turbo_pushed_at.blank?

      project.turbo_pushed_at > pushed_at
    end

    def ignored(project)
      Result.new(ok?: true, status: :ok, project:)
    end

    def pushed_at
      return @pushed_at if defined?(@pushed_at)

      raw = payload["pushed_at"].presence
      @pushed_at = raw && Time.iso8601(raw)
    rescue ArgumentError
      @pushed_at = nil
    end

    def possession_on
      return @possession_on if defined?(@possession_on)

      raw = payload["possession_on"].presence
      @possession_on = raw && Date.iso8601(raw)
    rescue Date::Error, ArgumentError
      @possession_on = nil
    end

    def attributes(city, builder, budget, brokerage)
      attrs = {
        name: payload["project_name"].to_s.strip,
        builder:,
        city:,
        locality: resolve_locality(city),
        address: payload["address"].presence,
        starting_budget: budget,
        possession_on:,
        possession_label: nil,
        rera_number: payload["rera_number"].to_s.strip.upcase,
        rm_name: payload["rm_name"].to_s.strip,
        rm_contact: payload["rm_contact"].to_s.gsub(/\D/, ""),
        company_code: payload["company_code"].presence,
        promo_text: payload["promo_text"].to_s.strip.presence,
        promo_ends_on: nil,
        status: "active",
        source: "catalog",
        firm_id: nil,
        turbo_pushed_at: pushed_at
      }
      # Absent on an older push. A blank value clears a percent that was stored.
      attrs[:brokerage_percent] = brokerage unless brokerage == :omit
      # The PDF stays on LaunchIQ. A blank brochure clears the link.
      # A URL on any other host leaves the stored link alone.
      attrs[:brochure_source_url] = remote_brochure_url unless remote_brochure_url == :omit
      # An out-of-India pin, or only one coordinate, leaves whatever is stored.
      lat = Project.coordinate(payload["lat"])
      lng = Project.coordinate(payload["lng"])
      if Project.pin_inside_india?(lat, lng)
        attrs[:lat] = lat
        attrs[:lng] = lng
      end
      attrs
    end

    # :omit leaves the stored link alone. nil clears it. A URL is kept only
    # when a broker can open it on LaunchIQ or the S3 host behind that redirect.
    def remote_brochure_url
      return @remote_brochure_url if defined?(@remote_brochure_url)

      @remote_brochure_url = accepted_brochure_url
    end

    def accepted_brochure_url
      return :omit unless payload.key?("brochure")

      row = payload["brochure"]
      return if row.blank?

      url = row.to_h.deep_stringify_keys["url"].to_s.strip
      return if url.blank?

      uri = URI.parse(url)
      return :omit unless uri.is_a?(URI::HTTPS) && RemoteFile.allowed_host?(uri)

      public_brochure_url(uri)
    rescue URI::InvalidURIError
      :omit
    end

    # LaunchIQ builds the file URL on APP_HOST. When that host is the API origin
    # and brokers open a different public origin, store the public host and keep
    # the path. The signed blob does not include the hostname.
    def public_brochure_url(uri)
      public_origin = URI.parse(Credentials.turbo_public_origin.to_s)
      api_host = URI.parse(Credentials.turbo_api_origin.to_s).host
      return uri.to_s if public_origin.host.blank? || api_host.blank?
      return uri.to_s unless uri.host.casecmp?(api_host) && !uri.host.casecmp?(public_origin.host)

      uri.scheme = public_origin.scheme
      uri.host = public_origin.host
      uri.port = public_origin.port
      uri.to_s
    rescue URI::InvalidURIError
      uri.to_s
    end

    def starting_brokerage
      return :omit unless payload.key?("brokerage_percent")

      raw = payload["brokerage_percent"]
      return if raw.blank?

      number = BigDecimal(raw.to_s)
      unless number.positive? && number <= 100
        return failure("brokerage_percent must be greater than 0 and at most 100")
      end

      number
    rescue ArgumentError
      failure("brokerage_percent is invalid")
    end

    def resolve_city
      name = payload["city"].to_s.strip
      return failure("city is required") if name.blank?

      found = cities_named(name)
      return failure("City #{name} matches more than one state") if found.size > 1
      return found.first if found.one?

      create_city(name)
    end

    # LaunchIQ is the only automatic creator. A missing state refuses the share.
    def create_city(name)
      state = state_for_new_city(name)
      return missing_state(name) if state.blank?

      city = City.create!(name:, state:, active: true)
      Rails.logger.info("[marketplace] created city #{city.name}, #{city.state}")
      city
    rescue ActiveRecord::RecordNotUnique
      found = cities_named(name)
      return failure("City #{name} matches more than one state") if found.size > 1
      return found.first if found.one?

      missing_state(name)
    end

    def state_for_new_city(name)
      geocoder = google_geocoder
      return if geocoder.nil?

      lat = payload["lat"]
      lng = payload["lng"]
      if IndiaPin.pin_inside_india?(lat, lng)
        geocoder.state_from_pin(lat, lng)
      else
        geocoder.state_from_city(name)
      end
    end

    def google_geocoder
      key = ENV["GOOGLE_GEOCODING_API_KEY"].presence
      return if key.blank?

      Localities::GoogleGeocoder.new(key)
    end

    def cities_named(name)
      City.where("LOWER(name) = ?", name.downcase).to_a
    end

    def missing_state(name)
      failure("City #{name} is not in RealtorIQ, and its state could not be found")
    end

    def resolve_locality(city)
      name = payload["locality"].to_s.strip
      found = find_named(Locality.where(city:), name)
      return found if found

      locality = Locality.create!(city:, name:)
      Rails.logger.info("[marketplace] created locality #{locality.name}")
      locality
    end

    def resolve_builder
      name = payload["developer_name"].to_s.strip
      return failure("developer_name is required") if name.blank?

      found = find_named(Builder.where(firm_id: nil), name)
      return found if found

      builder = Builder.create!(name:, firm_id: nil, active: true)
      Rails.logger.info("[marketplace] created builder #{builder.name}")
      builder
    end

    def find_named(scope, name)
      key = NameKey.call(name)
      return if key.blank?

      rows = scope.to_a
      rows.find { |row| row.respond_to?(:active?) && row.active? && NameKey.call(row.name) == key } ||
        rows.find { |row| NameKey.call(row.name) == key }
    end

    # Every LaunchIQ unit is its own row. Rows that resolve to the same
    # configuration and the same label keep the lowest price.
    def unit_rows
      built = []
      Array(payload["unit_types"]).each do |row|
        parsed = unit_row(row)
        return parsed if parsed.is_a?(Result)

        built << parsed if parsed
      end
      return failure("at least one configuration is required") if built.empty?

      built.group_by { |row| [ row[:typology].id, row[:label].to_s.downcase ] }
        .map { |_key, group| group.min_by { |row| [ row[:starting_price].nil? ? 1 : 0, row[:starting_price].to_i ] } }
    end

    def unit_row(row)
      row = row.to_h.deep_stringify_keys
      typology_name = row["typology_name"].to_s
      unit_label = row["label"].to_s
      return if typology_name.strip.blank? && unit_label.strip.blank?

      resolved = UnitResolver.call(
        typology_name:,
        typology_category: row["typology_category"],
        label: unit_label
      )
      return failure("a configuration could not be resolved") if resolved.typology.nil?

      {
        typology: resolved.typology,
        label: variant_label(unit_label, typology_name, resolved),
        starting_price: integer_rupees(row["price_min"]),
        needs_review: resolved.needs_review,
        review_note: review_note(resolved, typology_name, unit_label, row["typology_category"]),
        **area_fields(row, resolved.typology)
      }
    end

    # The unit label, otherwise the configuration name, whichever still says
    # something after the row drops a label that only repeats the configuration.
    # A generic configuration name is not a label. Neither is the configuration
    # name when its BHK disagreed with the unit label.
    def variant_label(unit_label, typology_name, resolved)
      kept = ProjectTypology.stored_label(unit_label, resolved.typology)
      return kept if kept
      return if resolved.bhk_conflict || Typology.generic_name?(typology_name)

      ProjectTypology.stored_label(typology_name, resolved.typology)
    end

    # Set whenever the row is flagged. The three sentences are the only
    # reasons ops sees on Review.
    def review_note(resolved, typology_name, unit_label, category)
      return unless resolved.needs_review

      text = case resolved.review
      when :bhk_conflict
        configuration = typology_name.strip
        label = unit_label.strip
        "LaunchIQ configuration \"#{configuration}\" disagrees with unit label \"#{label}\". " \
          "Fix the unit in LaunchIQ, then push again."
      when :bare_plot
        "LaunchIQ sent only \"#{bare_plot_text(typology_name, unit_label)}\". Confirm the plot type."
      else
        shown = [ typology_name.strip, unit_label.strip ].find(&:present?)
        category_text = category.to_s.strip.presence || "none"
        "Couldn't classify \"#{shown}\" (LaunchIQ category: #{category_text})."
      end
      text[0, ProjectTypology::REVIEW_NOTE_LIMIT]
    end

    def bare_plot_text(typology_name, unit_label)
      [ typology_name, unit_label ].map(&:strip).find { |text| text.match?(/plot|land/i) } ||
        [ typology_name, unit_label ].map(&:strip).find(&:present?)
    end

    # LaunchIQ allows sqm on any unit. After the configuration is known, a
    # home or office is stored in sq ft (AreaUnits, 10.7639). A plot keeps
    # the typed sqm.
    def area_fields(row, typology)
      raw = row["area_min"]
      return {} if raw.blank?

      number = raw.is_a?(String) ? BigDecimal(raw) : raw.to_d
      return {} unless number.positive?

      unit = row["area_unit"].to_s == "sqm" ? "sqm" : "sqft"
      if unit == "sqm" && !typology.land?
        return { area_value: AreaUnits.to_sqft(number, "sqm"), area_unit: "sqft" }
      end

      { area_value: number, area_unit: unit }
    rescue ArgumentError
      {}
    end

    def integer_rupees(value)
      return if value.blank?

      number = value.is_a?(String) ? BigDecimal(value) : value.to_d
      rounded = number.round(0, :half_up).to_i
      rounded.positive? ? rounded : nil
    rescue ArgumentError
      nil
    end

    def replace_typologies(project, rows)
      project.project_typologies.destroy_all
      rows.each do |row|
        project.project_typologies.create!(
          typology: row[:typology],
          label: row[:label],
          starting_price: row[:starting_price],
          area_value: row[:area_value],
          area_unit: row[:area_unit].presence || "sqft",
          needs_review: row[:needs_review],
          review_note: row[:review_note]
        )
      end
    end

    def repoint_copies(project, previous_builder_id)
      # update_all skips the model callback. A coordinate that actually moves
      # is a real pin, so the centre stand-in flag has to clear with it.
      Project.unscoped.where(external_ref: project.external_ref, source: "own").update_all(
        [
          <<~SQL.squish,
            builder_id = ?, address = ?, lat = ?, lng = ?, updated_at = ?,
            pin_approximate = CASE
              WHEN lat IS DISTINCT FROM ? OR lng IS DISTINCT FROM ? THEN FALSE
              ELSE pin_approximate
            END
          SQL
          project.builder_id, project.address, project.lat, project.lng, Time.current,
          project.lat, project.lng
        ]
      )
      return if previous_builder_id.blank? || previous_builder_id == project.builder_id

      old = Builder.find_by(id: previous_builder_id)
      return unless old&.name&.match?(CODE_BUILDER)
      return if Project.unscoped.exists?(builder_id: old.id)

      old.update!(active: false)
    end

    # A withdraw archives the firm's copies. The next upsert brings those back.
    # A copy the firm archived on its own stays archived unless the catalog
    # itself was archived (hide or withdraw) and is now live again.
    def restore_after_archive(project, was_archived)
      ids = Project.unscoped.where(external_ref: project.external_ref).pluck(:id)
      LeadProject.across_firms.where(project_id: ids).where.not(withdrawn_at: nil).update_all(
        withdrawn_at: nil, updated_at: Time.current
      )
      return unless was_archived

      Project.unscoped.where(external_ref: project.external_ref, source: "own", status: "archived").update_all(
        status: "active", updated_at: Time.current
      )
    end

    def image_rows
      Array(payload["images"]).filter_map { |row| file_payload(row) }
    end

    # nil leaves an existing ladder alone (older events). A present key with
    # no file removes it. The image is copied; the brochure is not.
    def brokerage_ladder_row
      return unless payload.key?("brokerage_ladder")

      file_payload(payload["brokerage_ladder"]) || { "purge" => true }
    end

    def file_payload(row)
      return if row.blank?

      data = row.to_h.deep_stringify_keys
      return if data["url"].blank? || data["checksum"].blank?

      data.slice("url", "checksum", "filename")
    end

    def failure(error)
      Result.new(ok?: false, status: :unprocessable_entity, error:)
    end
  end
end
