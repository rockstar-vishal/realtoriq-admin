# frozen_string_literal: true

module Matches
  # One pass over a firm's leads and its own listings. MatchScore, the locality
  # gate, the floors, and the possession rules are the live matcher's. Already
  # linked rows are left out in both directions. MatchLeads still returns them.
  class CurateFirm
    LEAD_CAP = 30
    LISTING_CAP = 30
    MATCH_CAP = Inventory::MatchInventory::LIMIT
    PRICE_BAND = BigDecimal("1.25")

    def self.call(firm:, announce: true)
      new(firm:, announce:).call
    end

    def self.fingerprint(lead_items, listing_items)
      payload = {
        leads: lead_items.map { |item| [ item["lead_id"], item["match_ids"].sort ] }.sort,
        listings: listing_items.map { |item| [ item["kind"], item["id"], item["match_ids"].sort ] }.sort
      }
      Digest::SHA256.hexdigest(JSON.generate(payload))
    end

    def initialize(firm:, announce: true)
      @firm = firm
      @announce = announce
    end

    def call
      return unless Current.firm_id == firm.id
      return unless Eligible.firm?(firm)

      ScanLock.with(firm) { write_digest }
    end

    private

    attr_reader :firm, :announce

    def write_digest
      previous = MatchDigest.find_by(firm_id: firm.id)
      lead_items, listing_items = items_for(previous)
      shown_leads = lead_items.first(LEAD_CAP)
      shown_listings = listing_items.first(LISTING_CAP)
      fingerprint = self.class.fingerprint(shown_leads, shown_listings)
      save(lead_items, listing_items, shown_leads, shown_listings, fingerprint, announce:)
    end

    def items_for(previous)
      read_anchor_switch
      nearby = nearby_on?
      locality_ids = matching_leads.joins(:lead_localities).distinct.pluck("lead_localities.locality_id")
      if nearby
        locality_ids |= LocalityNeighbor.where(locality_id: locality_ids).pluck(:neighbor_locality_id)
      end
      boxes = pin_boxes(nearby:)
      return [ [], [] ] if locality_ids.empty? && boxes.empty?

      pool = InventoryPool.call(
        locality_ids:, price_cap:, boxes:, centers: !anchors_on?, hide_listed_copies: anchors_on?
      )
      previous_leads = index_items(previous&.lead_items, "lead_id")
      previous_listings = index_listings(previous&.listing_items)
      buckets = {}
      lead_items = []

      matching_leads.find_in_batches(batch_size: 100) do |batch|
        preload_leads(batch)
        index = Inventory::HookIndex.for(batch, nearby:, anchors: anchors_on?, radius_m: anchor_radius)
        batch.each do |lead|
          hooks = Inventory::LeadHooks.for(lead, index:)
          scored = score_lead(lead, pool, hooks)
          next if scored.empty?

          scored.each { |row| collect_listing(buckets, lead, row, hooks) }
          lead_items << lead_item(lead, scored, previous_leads[lead.id])
        end
      end

      [ top_leads(lead_items), top_listings(buckets, previous_listings) ]
    end

    def preload_leads(batch)
      ActiveRecord::Associations::Preloader.new(
        records: batch,
        associations: [ :typologies, :localities, :property_type, :lead_status, :lead_projects, :lead_properties ]
      ).call
    end

    # One lead with no budget lifts the ceiling. Otherwise that lead never
    # sees a marketplace listing above the dearest stored budget.
    def price_cap
      return if matching_leads.where("COALESCE(budget_max, budget_min, 0) = 0").exists?

      max = matching_leads.pick(Arel.sql("MAX(COALESCE(budget_max, budget_min))"))
      return if max.nil?

      (max.to_d * PRICE_BAND).ceil.to_i
    end

    def score_lead(lead, pool, hooks)
      circles = hooks.anchor_mode? ? hooks.anchors : hooks.pins
      return [] if hooks.preferred_ids.empty? && circles.empty?

      @decisions = {}
      keys = lead.typologies.map { |typology| Inventory::ConfigurationKey.call(typology.name) }
      mapped_projects = lead.lead_projects.reject { |row| row.withdrawn_at.present? }.map(&:project_id)
      mapped_properties = lead.lead_properties.map(&:property_id)
      if hooks.anchor_mode?
        mapped_projects = Inventory::ProjectTwins.expand(mapped_projects, firm_id: firm.id)
        mapped_projects |= Inventory::ProjectTwins.expand(hooks.visited_project_ids, firm_id: firm.id)
        mapped_properties |= hooks.visited_property_ids
      end
      mapped_projects = mapped_projects.to_set
      mapped_properties = mapped_properties.to_set
      candidates = candidates_for(lead, pool, hooks)

      candidates.filter_map { |item| scored_row(item, lead, keys, mapped_projects, mapped_properties, hooks) }
        .sort_by { |row| row[:sort] }
        .first(MATCH_CAP)
    ensure
      @decisions = nil
    end

    def candidates_for(lead, pool, hooks)
      chosen = []
      unless lead.rent?
        chosen.concat(pool[:projects].select { |item| show_project?(lead, item, hooks) })
      end
      if show_properties?(lead)
        chosen.concat(pool[:properties].select { |item| show_property?(lead, item, hooks) })
      end
      chosen
    end

    def show_properties?(lead)
      !(Inventory::Fit.possession_applies?(lead) && !lead.ready_possession?)
    end

    def show_project?(lead, item, hooks)
      decision_for(hooks, item) && (!lead.ready_possession? || item.ready) && scoped_offers(lead, item).any?
    end

    def show_property?(lead, item, hooks)
      decision_for(hooks, item) && item.listing_for == lead.transaction_type && scoped_offers(lead, item).any?
    end

    def scoped_offers(lead, item)
      item.offers.select { |offer|
        Inventory::Fit.row_in_scope?(lead, Inventory::Fit::Ref.new(id: offer.typology_id, category: offer.category))
      }
    end

    def decision_for(hooks, item)
      key = [ item.kind, item.id ]
      return @decisions[key] if @decisions.key?(key)

      @decisions[key] = Inventory::CandidateRank.decide(
        hooks:,
        locality_id: item.locality_id,
        lat: item.lat, lng: item.lng,
        locality_lat: item.locality_lat, locality_lng: item.locality_lng,
        round_distance: item.kind == "property" && item.marketplace,
        approximate: item.approximate
      )
    end

    def scored_row(item, lead, keys, mapped_projects, mapped_properties, hooks)
      return if item.kind == "project" && mapped_projects.include?(item.id)
      return if item.kind == "property" && mapped_properties.include?(item.id)

      decision = decision_for(hooks, item)
      return unless decision

      offers = scoped_offers(lead, item)
      return if offers.empty?

      breakdown = Inventory::MatchScore.for_offers(
        budget: lead.budget_amount,
        offers:,
        lead_keys: keys,
        fallback_price: Inventory::Fit.fallback_price(lead, item.price_source),
        location_points: decision.location_points,
        fit: lead.category == "residential" ? :configuration : :area,
        bonus: Inventory::Fit.pre_leased_bonus(lead, item),
        lead:
      )
      return unless breakdown[:score] > item.floor

      {
        item:, score: breakdown[:score], decision:,
        sort: Inventory::CandidateRank.sort_key(
          ranking: hooks.ranking?, decision:, score: breakdown[:score], name: item.name,
          pre_leased_first: Inventory::Fit.pre_leased_first?(lead, item), tie: item.id
        )
      }
    end

    def pin_boxes(nearby:)
      return [] unless nearby
      return anchor_boxes if anchors_on?

      projects = Project.unscoped.where(
        id: LeadProject.where(lead_id: matching_leads.select(:id), withdrawn_at: nil).select(:project_id)
      ).includes(:locality)
      properties = Property.unscoped.where(
        id: LeadProperty.where(lead_id: matching_leads.select(:id)).select(:property_id)
      ).includes(:locality)
      points = []
      projects.find_each do |project|
        point = Inventory::Geo.listing_point(
          lat: project.lat, lng: project.lng,
          locality_lat: project.locality&.lat, locality_lng: project.locality&.lng,
          approximate: project.pin_approximate
        )
        points << point.merge(city_id: project.city_id) if point && project.city_id
      end
      properties.each do |property|
        point = Inventory::Geo.listing_point(
          lat: property.lat, lng: property.lng,
          locality_lat: property.locality&.lat, locality_lng: property.locality&.lng,
          approximate: property.pin_approximate
        )
        points << point.merge(city_id: property.city_id) if point && property.city_id
      end
      points.uniq { |point| [ point[:city_id], point[:lat], point[:lng] ] }.map { |point|
        box = Inventory::Geo.box(point[:lat], point[:lng])
        { city_id: point[:city_id], min_lat: box.min_lat, max_lat: box.max_lat, min_lng: box.min_lng, max_lng: box.max_lng }
      }
    end

    def anchor_boxes
      points = []
      matching_leads.find_in_batches(batch_size: 500) do |batch|
        Inventory::LeadAnchors.for(batch).anchors.each_value do |anchors|
          anchors.each { |anchor| points << [ anchor.lat, anchor.lng ] }
        end
      end
      points.uniq.map do |lat, lng|
        box = Inventory::Geo.box(lat, lng, metres: anchor_radius + 150)
        { min_lat: box.min_lat, max_lat: box.max_lat, min_lng: box.min_lng, max_lng: box.max_lng }
      end
    end

    def read_anchor_switch
      return if defined?(@anchor_radius)

      @anchor_radius = ::AnchorMatching.pick(:radius_m)
    end

    def anchors_on?
      read_anchor_switch
      !@anchor_radius.nil?
    end

    def anchor_radius
      read_anchor_switch
      @anchor_radius
    end

    def nearby_on?
      return @nearby_on unless @nearby_on.nil?

      @nearby_on = ::NearbyMatching.enabled? || anchors_on?
    end

    def collect_listing(buckets, lead, row, hooks)
      item = row[:item]
      return if item.marketplace

      key = [ item.kind, item.id ]
      bucket = buckets[key] ||= {
        "kind" => item.kind, "id" => item.id, "title" => item.name,
        "listing_for" => item.listing_for, "categories" => listing_categories(item), "leads" => []
      }
      buyer_sort = Inventory::CandidateRank.sort_key(
        ranking: hooks.ranking?, decision: row[:decision], score: row[:score], name: lead.display_name,
        pre_leased_first: Inventory::Fit.pre_leased_first?(lead, item), tie: lead.id
      )
      bucket["leads"] << {
        "lead_id" => lead.id, "name" => lead.display_name, "score" => row[:score], "_sort" => buyer_sort
      }
    end

    def lead_item(lead, scored, previous)
      match_ids = scored.map { |row| "#{row[:item].kind}:#{row[:item].id}" }
      {
        "lead_id" => lead.id,
        "code" => lead.code,
        "name" => lead.display_name,
        "budget" => lead.budget_amount,
        "typologies" => lead.typologies.map(&:name).sort,
        "localities" => lead.localities.map(&:name).sort,
        "dead" => lead.lead_status&.is_dead? == true,
        "match_count" => match_ids.size,
        "new_count" => new_count(match_ids, previous&.dig("match_ids")),
        "top_score" => scored.max_by { |row| row[:score] }[:score],
        "match_ids" => match_ids,
        "category" => lead.category,
        "area" => lead.area_payload,
        "prefers_pre_leased" => lead.prefers_pre_leased
      }
    end

    # Every match, in the order the page uses. The 30-row cap is applied
    # only when the list is shown, fingerprinted, or announced.
    def top_leads(items)
      items.sort_by { |item| [ -item["top_score"], item["name"].to_s.downcase, item["lead_id"].to_s ] }
    end

    def top_listings(buckets, previous_listings)
      buckets.values.filter_map { |bucket| listing_item(bucket, previous_listings) }
        .sort_by { |item| [ -item["top_score"], item["title"].to_s.downcase, item["id"].to_s ] }
    end

    def listing_item(bucket, previous_listings)
      leads = bucket["leads"].sort_by { |row| row["_sort"] }
        .first(MATCH_CAP)
      leads.each { |row| row.delete("_sort") }
      return if leads.empty?

      match_ids = leads.map { |row| row["lead_id"] }
      previous = previous_listings[[ bucket["kind"], bucket["id"] ]]
      item = {
        "kind" => bucket["kind"],
        "id" => bucket["id"],
        "title" => bucket["title"],
        "match_count" => match_ids.size,
        "new_count" => new_count(match_ids, previous&.dig("match_ids")),
        "top_score" => leads.max_by { |row| row["score"] }["score"],
        "match_ids" => match_ids
      }
      item["listing_for"] = bucket["listing_for"] if bucket["listing_for"].present?
      item["categories"] = bucket["categories"] if bucket.key?("categories")
      item
    end

    def listing_categories(item)
      found = Array(item.offers).filter_map(&:category)
      Typology::CATEGORY_ORDER & found
    end

    def new_count(ids, previous_ids)
      previous = Array(previous_ids).to_set
      ids.count { |id| !previous.include?(id) }
    end

    # Booked leads are a closed deal. Dead leads stay, and the page marks them.
    def matching_leads
      Lead.matchable
    end

    def index_items(items, key)
      Array(items).index_by { |item| item[key] }
    end

    def index_listings(items)
      Array(items).index_by { |item| [ item["kind"], item["id"] ] }
    end

    # The morning release can send the ping and clear the flag while scoring
    # is still running, so the decision re-reads the row under a lock.
    # Writing the stale flag back is what queued a second ping for a list
    # that had already been sent. Notify runs after the commit: a duplicate
    # dedupe key, or a push that raises, must not roll the saved list back,
    # and the push must not sit on the row lock.
    def save(lead_items, listing_items, shown_leads, shown_listings, fingerprint, announce:)
      attempts = 0
      saved = nil
      notify = false
      begin
        saved = MatchDigest.transaction do
          current = MatchDigest.lock.find_by(firm_id: firm.id)
          should_announce = announce && announce?(shown_leads, shown_listings, current)
          digest = current || MatchDigest.new(firm:)
          digest.assign_attributes(generated_at: Time.current, fingerprint:, lead_items:, listing_items:)
          if announce
            # One reading. A second call can cross 21:00 or 08:00 and leave
            # the pending flag and the push on opposite sides of the night.
            quiet = Slot.quiet?
            apply_notification(digest, current, should_announce, quiet:)
            notify = should_announce && !quiet
          else
            digest.notification_pending = false
            digest.notified_fingerprint = fingerprint
            notify = false
          end
          digest.save!
          digest
        end
      rescue ActiveRecord::RecordNotUnique
        attempts += 1
        retry if attempts < 2

        raise
      end
      deliver_notification(saved) if notify
      saved
    end

    def deliver_notification(digest)
      Notify.call(digest:)
    rescue StandardError => error
      Rails.logger.error("[matches] notify failed for firm #{digest.firm_id}: #{error.class}: #{error.message}")
    end

    def announce?(lead_items, listing_items, previous)
      return false if lead_items.empty? && listing_items.empty?
      return true if previous.nil?

      new_total(lead_items, listing_items).positive?
    end

    def new_total(lead_items, listing_items)
      (lead_items + listing_items).sum { |item| item["new_count"].to_i }
    end

    def apply_notification(digest, previous, announce, quiet:)
      if announce && quiet
        digest.notification_pending = true
      elsif announce
        digest.notification_pending = false
        digest.notified_fingerprint = digest.fingerprint
      else
        still_waiting = previous&.notification_pending && (digest.lead_items.any? || digest.listing_items.any?)
        digest.notification_pending = still_waiting == true
      end
    end
  end
end
