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

      url
    rescue URI::InvalidURIError
      :omit
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

      matches = City.where("LOWER(name) = ?", name.downcase).to_a
      return failure("City #{name} is not in RealtorIQ") if matches.empty?
      return failure("City #{name} matches more than one state") if matches.size > 1

      matches.first
    end

    def resolve_locality(city)
      name = payload["locality"].to_s.strip
      return if name.blank?

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

    def unit_rows
      rows = Array(payload["unit_types"])
      built = rows.filter_map { |row| unit_row(row) }
      return failure("at least one configuration is required") if built.empty?

      built.group_by { |row| row[:typology].id }.map do |_id, group|
        group.min_by { |row| row[:starting_price] || Float::INFINITY }
      end
    end

    def unit_row(row)
      row = row.to_h.deep_stringify_keys
      label = row["typology_name"].presence || row["label"].presence
      return if label.blank?

      typology = find_named(Typology.all, label) || create_typology(label)
      price = integer_rupees(row["price_min"])
      {
        typology:,
        starting_price: price,
        starting_carpet_sqft: carpet(row)
      }
    end

    def create_typology(name)
      match = name.match(/(\d+(?:\.5)?)\s*bhk/i)
      typology = Typology.create!(
        name:,
        bedrooms: match && BigDecimal(match[1]),
        sort_order: Typology.maximum(:sort_order).to_i + 1
      )
      Rails.logger.info("[marketplace] created typology #{typology.name}")
      typology
    end

    def integer_rupees(value)
      return if value.blank?

      number = value.is_a?(String) ? BigDecimal(value) : value.to_d
      rounded = number.round(0, :half_up).to_i
      rounded.positive? ? rounded : nil
    rescue ArgumentError
      nil
    end

    def carpet(row)
      value = row["area_min"]
      return if value.blank?

      number = value.to_d
      number *= BigDecimal("10.764") if row["area_unit"].to_s == "sqm"
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
          starting_price: row[:starting_price],
          starting_carpet_sqft: row[:starting_carpet_sqft]
        )
      end
    end

    def repoint_copies(project, previous_builder_id)
      Project.unscoped.where(external_ref: project.external_ref, source: "own").update_all(
        builder_id: project.builder_id, updated_at: Time.current
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
